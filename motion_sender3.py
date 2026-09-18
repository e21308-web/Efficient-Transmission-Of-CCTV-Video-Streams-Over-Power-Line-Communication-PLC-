import socket
import struct
import time
import heapq
from collections import Counter

import cv2
import numpy as np

# ============================================================
# RASPBERRY PI VIDEO SENDER - v3, instrumented
#
# Your test run showed ~1.9-2.4 fps at 320x176 (~500 ms/frame) on
# the real Pi 3, vs ~20-30 ms/frame I measured on my dev machine.
# That ~20x gap is bigger than raw CPU-speed difference alone would
# explain, so shrinking resolution further is a guess, not a fix,
# until we know WHERE the time is actually going on your hardware:
# camera capture? motion search? the DCT/quant math? Huffman?
#
# This version:
#   1. Prints a per-stage timing breakdown every second (capture,
#      motion+transform, huffman, send) so the next run tells us the
#      real bottleneck instead of guessing again.
#   2. Drops the default resolution to 160x96 (less work regardless
#      of where the bottleneck turns out to be).
#   3. Adds FAST_MODE: when True, skips Huffman entirely and packs
#      symbols as fixed-width bytes (numpy .astype().tobytes(), no
#      Python-level loop at all). This trades bitrate for speed --
#      your last run only used ~170 kbps out of an available budget,
#      so there's room. If Huffman turns out to be your bottleneck,
#      this alone may get you to 15 fps.
#
# RUN THIS FIRST, then send me the printed stage breakdown (the line
# starting "Stage timing:") -- that tells us exactly what to fix
# next, rather than guessing a third or fourth time.
# ============================================================

DEST_IP = "192.168.137.1"   # <-- CHECK THIS: must be your PC's actual IP
DEST_PORT = 5005

WIDTH = 160
HEIGHT = 96
FPS = 15

MB = 16
N = 8
SEARCH_RANGE = 4
ZERO_MV_SAD_THRESHOLD = 2.0

GOP_SIZE = 10

MIN_BITRATE_KBPS = 500.0
MAX_BITRATE_KBPS = 1000.0
TARGET_BITRATE_KBPS = 750.0

Q_SCALE = 1.0
Q_SCALE_MIN = 0.25
Q_SCALE_MAX = 4.0
Q_SCALE_DOWN = 0.08
Q_SCALE_UP = 0.10

SHOW_PREVIEW = False

# If True: skip Huffman, pack symbols as fixed-width int16 bytes.
# Bigger packets, but zero per-symbol Python work.
FAST_MODE = True

MAX_PAYLOAD = 60000
HEADER = struct.Struct("!IHHBB")

Q50 = np.array([
    [16, 11, 10, 16, 24, 40, 51, 61],
    [12, 12, 14, 19, 26, 58, 60, 55],
    [14, 13, 16, 24, 40, 57, 69, 56],
    [14, 17, 22, 29, 51, 87, 80, 62],
    [18, 22, 37, 56, 68, 109, 103, 77],
    [24, 35, 55, 64, 81, 104, 113, 92],
    [49, 64, 78, 87, 103, 121, 120, 101],
    [72, 92, 95, 98, 112, 100, 103, 99],
], dtype=np.float32)

ZIGZAG_ARR = np.array([
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
])

_n = np.arange(8)
_k = np.arange(8).reshape(-1, 1)
DCT_T = (np.sqrt(2 / 8) * np.cos(np.pi / 8 * (_n + 0.5) * _k)).astype(np.float32)
DCT_T[0, :] *= 1 / np.sqrt(2)


def build_quant_matrix(quality=23, scale=1.0):
    quality = int(np.clip(quality, 1, 100))
    s = 5000 / quality if quality < 50 else 200 - 2 * quality
    q = np.floor((Q50 * s + 50) / 100)
    q = np.clip(q, 1, 255)
    return np.maximum(1, np.round(q * scale)).astype(np.float32)


def dct2_batch(blocks):
    return np.matmul(np.matmul(DCT_T, blocks), DCT_T.T)


def idct2_batch(D):
    return np.matmul(np.matmul(DCT_T.T, D), DCT_T)


def extract_tiles(arr, tile):
    H, W = arr.shape
    rows, cols = H // tile, W // tile
    return arr.reshape(rows, tile, cols, tile).transpose(0, 2, 1, 3).reshape(rows * cols, tile, tile), rows, cols


def assemble_tiles(tiles, rows, cols, tile):
    return tiles.reshape(rows, cols, tile, tile).transpose(0, 2, 1, 3).reshape(rows * tile, cols * tile)


def split_mb_to_sub(mb_tiles):
    num_mb = mb_tiles.shape[0]
    return mb_tiles.reshape(num_mb, 2, 8, 2, 8).transpose(0, 1, 3, 2, 4).reshape(num_mb * 4, 8, 8)


def merge_sub_to_mb(sub_blocks, num_mb):
    return sub_blocks.reshape(num_mb, 2, 2, 8, 8).transpose(0, 1, 3, 2, 4).reshape(num_mb, 16, 16)


def huffman_code_lengths(values):
    freq = Counter(values)
    if len(freq) == 1:
        return {next(iter(freq)): 1}
    heap = []
    counter = 0
    for sym, f in freq.items():
        heapq.heappush(heap, (f, counter, sym))
        counter += 1
    while len(heap) > 1:
        f1, _, a = heapq.heappop(heap)
        f2, _, b = heapq.heappop(heap)
        heapq.heappush(heap, (f1 + f2, counter, (a, b)))
        counter += 1
    root = heap[0][2]
    lengths = {}

    def walk(node, depth):
        if isinstance(node, tuple):
            walk(node[0], depth + 1)
            walk(node[1], depth + 1)
        else:
            lengths[node] = max(1, depth)

    walk(root, 0)
    return lengths


def canonical_codes(lengths):
    items = sorted(lengths.items(), key=lambda x: (x[1], x[0]))
    codes = {}
    code = 0
    previous_length = 0
    for symbol, length in items:
        code <<= (length - previous_length)
        codes[symbol] = (code, length)
        code += 1
        previous_length = length
    return codes


def pack_huffman(values):
    values_arr = np.asarray(values, dtype=np.int64)
    lengths = huffman_code_lengths(values)
    codes = canonical_codes(lengths)

    sorted_syms = np.array(sorted(codes.keys()), dtype=np.int64)
    code_arr = np.array([codes[s][0] for s in sorted_syms], dtype=np.int64)
    length_arr = np.array([codes[s][1] for s in sorted_syms], dtype=np.int64)

    idx = np.searchsorted(sorted_syms, values_arr)
    inst_code = code_arr[idx]
    inst_len = length_arr[idx]

    starts = np.empty_like(inst_len)
    starts[0] = 0
    if len(inst_len) > 1:
        np.cumsum(inst_len[:-1], out=starts[1:])
    total_bits = int(inst_len.sum())

    l_max = int(inst_len.max()) if len(inst_len) else 0
    bitbuf = np.zeros(total_bits, dtype=np.uint8)

    for k in range(l_max):
        mask = k < inst_len
        if not np.any(mask):
            continue
        shift = inst_len[mask] - 1 - k
        bitval = (inst_code[mask] >> shift) & 1
        bitbuf[starts[mask] + k] = bitval.astype(np.uint8)

    padding = (8 - total_bits % 8) % 8
    if padding:
        bitbuf = np.concatenate([bitbuf, np.zeros(padding, dtype=np.uint8)])
    data = np.packbits(bitbuf).tobytes()

    output = bytearray()
    output += struct.pack("!H", len(lengths))
    for symbol, length in sorted(lengths.items()):
        output += struct.pack("!iB", int(symbol), int(length))
    output += struct.pack("!BI", padding, len(data))
    output += data
    return bytes(output)


def pack_fixed(values):
    """FAST_MODE encoder: fixed-width int16 per symbol, no Python loop
    at all. No compression, but essentially free to compute. Values
    are clipped to int16 range (plenty for quantized DCT coefficients
    at any sane Q-scale)."""
    arr = np.clip(np.asarray(values, dtype=np.int32), -32767, 32767).astype(">i2")
    return arr.tobytes()


def motion_search(cur, reference, r, c, mb, search_range):
    H, W = cur.shape
    current_block = cur[r:r + mb, c:c + mb]

    zero_ref = reference[r:r + mb, c:c + mb]
    if np.mean(np.abs(current_block - zero_ref)) < ZERO_MV_SAD_THRESHOLD:
        return 0, 0

    r1 = max(0, r - search_range)
    r2 = min(H - mb, r + search_range)
    c1 = max(0, c - search_range)
    c2 = min(W - mb, c + search_range)

    search_area = reference[r1:r2 + mb, c1:c2 + mb]
    result = cv2.matchTemplate(search_area, current_block, cv2.TM_SQDIFF)
    _, _, min_loc, _ = cv2.minMaxLoc(result)
    return (r1 + min_loc[1]) - r, (c1 + min_loc[0]) - c


def _symbols_from_residual(residual_frame, Q, Q_zz, rows, cols):
    num_mb = rows * cols
    mb_tiles, _, _ = extract_tiles(residual_frame, MB)
    sub_blocks = split_mb_to_sub(mb_tiles)

    D = dct2_batch(sub_blocks)
    quantised = np.round(D / Q)
    flat = quantised.reshape(-1, 64)[:, ZIGZAG_ARR]

    dc_vals = flat[:, 0]
    dc_diffs = np.empty_like(dc_vals)
    dc_diffs[0] = dc_vals[0]
    dc_diffs[1:] = dc_vals[1:] - dc_vals[:-1]
    symbols_array = flat.copy()
    symbols_array[:, 0] = dc_diffs
    all_symbols = symbols_array.astype(np.int32).flatten().tolist()

    dequant = np.zeros_like(flat)
    dequant[:, ZIGZAG_ARR] = flat * Q_zz
    recon_sub = idct2_batch(dequant.reshape(-1, 8, 8))
    recon_mb = merge_sub_to_mb(recon_sub, num_mb)
    recon_residual = assemble_tiles(recon_mb, rows, cols, MB)
    return all_symbols, recon_residual


def encode_i_frame(frame, qscale):
    H, W = frame.shape
    rows, cols = H // MB, W // MB
    Q = build_quant_matrix(23, qscale)
    Q_zz = Q.flatten()[ZIGZAG_ARR]

    all_symbols, recon_residual = _symbols_from_residual(frame, Q, Q_zz, rows, cols)
    reconstruction = np.clip(recon_residual, 0, 255)

    mse = np.mean((frame - reconstruction) ** 2)
    psnr = 99.0 if mse < 1e-12 else 10 * np.log10((255 ** 2) / mse)
    return all_symbols, reconstruction, psnr


def encode_p_frame(frame, reference, qscale):
    H, W = frame.shape
    rows, cols = H // MB, W // MB
    Q = build_quant_matrix(23, qscale)
    Q_zz = Q.flatten()[ZIGZAG_ARR]

    compensated = np.empty_like(frame)
    motion_vectors = []
    for r in range(0, H, MB):
        for c in range(0, W, MB):
            dy, dx = motion_search(frame, reference, r, c, MB, SEARCH_RANGE)
            compensated[r:r + MB, c:c + MB] = reference[r + dy:r + dy + MB, c + dx:c + dx + MB]
            motion_vectors.append((dy, dx))

    residual_frame = frame - compensated
    all_symbols, recon_residual = _symbols_from_residual(residual_frame, Q, Q_zz, rows, cols)
    reconstruction = np.clip(compensated + recon_residual, 0, 255)

    mse = np.mean((frame - reconstruction) ** 2)
    psnr = 99.0 if mse < 1e-12 else 10 * np.log10((255 ** 2) / mse)
    return all_symbols, motion_vectors, reconstruction, psnr


def serialize_frame(all_symbols, motion_vectors, qscale, psnr, width, height, is_i_frame):
    num_macroblocks = (width // MB) * (height // MB)
    output = bytearray(b"VC34" if FAST_MODE else b"VC33")
    output += struct.pack(
        "!HHBffH", width, height, 0 if is_i_frame else 1, float(qscale), float(psnr), num_macroblocks
    )
    if not is_i_frame:
        for dy, dx in motion_vectors:
            output += struct.pack("!bb", int(dy), int(dx))
    output += pack_fixed(all_symbols) if FAST_MODE else pack_huffman(all_symbols)
    return bytes(output)


def send_compressed_frame(sock, compressed_data, frame_id, frame_type, qscale):
    total_chunks = (len(compressed_data) + MAX_PAYLOAD - 1) // MAX_PAYLOAD
    total_sent = 0
    for chunk_index in range(total_chunks):
        start = chunk_index * MAX_PAYLOAD
        end = min(start + MAX_PAYLOAD, len(compressed_data))
        chunk = compressed_data[start:end]
        header = HEADER.pack(
            frame_id, chunk_index, total_chunks, frame_type,
            int(np.clip(round(qscale * 50), 0, 255)),
        )
        sock.sendto(header + chunk, (DEST_IP, DEST_PORT))
        total_sent += len(chunk)
    return total_sent


def update_qscale(qscale, measured_kbps):
    if measured_kbps > MAX_BITRATE_KBPS:
        qscale += Q_SCALE_UP
    elif measured_kbps < MIN_BITRATE_KBPS:
        qscale -= Q_SCALE_DOWN
    elif measured_kbps > TARGET_BITRATE_KBPS + 100:
        qscale += 0.03
    elif measured_kbps < TARGET_BITRATE_KBPS - 100:
        qscale -= 0.03
    return float(np.clip(qscale, Q_SCALE_MIN, Q_SCALE_MAX))


def setup_camera():
    from picamera2 import Picamera2

    picam2 = Picamera2()
    config = picam2.create_video_configuration(main={"size": (WIDTH, HEIGHT), "format": "RGB888"})
    picam2.configure(config)
    picam2.start()
    time.sleep(2)
    return picam2


def main():
    global Q_SCALE

    picam2 = setup_camera()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)

    previous_reconstruction = None
    frame_id = 0
    interval = 1.0 / FPS
    next_time = time.perf_counter()

    bytes_in_window = 0
    last_stats_time = time.perf_counter()
    frames_in_window = 0
    psnr = 0.0

    # Per-stage timing accumulators (reset every stats window)
    t_capture = t_encode = t_pack = t_send = 0.0

    print()
    print("==============================================")
    print("   RASPBERRY PI VIDEO SENDER (instrumented, FAST_MODE=%s)" % FAST_MODE)
    print("==============================================")
    print(f"Destination      : {DEST_IP}:{DEST_PORT}")
    print(f"Resolution       : {WIDTH} x {HEIGHT}")
    print(f"Target frame rate: {FPS} FPS")
    print(f"GOP size         : {GOP_SIZE}")
    print("==============================================")
    print("Watch 'Stage timing' below - it tells us where the time")
    print("actually goes on this hardware.")
    print("==============================================")
    print()

    try:
        while True:
            t0 = time.perf_counter()
            frame_rgb = picam2.capture_array()
            if frame_rgb.shape[0] != HEIGHT or frame_rgb.shape[1] != WIDTH:
                frame_rgb = cv2.resize(frame_rgb, (WIDTH, HEIGHT), interpolation=cv2.INTER_AREA)
            gray = cv2.cvtColor(frame_rgb, cv2.COLOR_RGB2GRAY).astype(np.float32)
            t1 = time.perf_counter()

            is_i_frame = previous_reconstruction is None or frame_id % GOP_SIZE == 0

            if is_i_frame:
                symbols, reconstruction, psnr = encode_i_frame(gray, Q_SCALE)
                motion_vectors = None
                frame_type, frame_label = 0, "I"
            else:
                symbols, motion_vectors, reconstruction, psnr = encode_p_frame(
                    gray, previous_reconstruction, Q_SCALE
                )
                frame_type, frame_label = 1, "P"
            t2 = time.perf_counter()

            compressed = serialize_frame(symbols, motion_vectors, Q_SCALE, psnr, WIDTH, HEIGHT, is_i_frame)
            t3 = time.perf_counter()

            sent_bytes = send_compressed_frame(sock, compressed, frame_id, frame_type, Q_SCALE)
            t4 = time.perf_counter()

            t_capture += t1 - t0
            t_encode += t2 - t1
            t_pack += t3 - t2
            t_send += t4 - t3

            bytes_in_window += sent_bytes
            frames_in_window += 1
            previous_reconstruction = reconstruction

            now = time.perf_counter()
            if now - last_stats_time >= 1.0:
                elapsed = now - last_stats_time
                measured_kbps = bytes_in_window * 8.0 / 1000.0 / elapsed
                fps = frames_in_window / elapsed
                old_qscale = Q_SCALE
                Q_SCALE = update_qscale(Q_SCALE, measured_kbps)
                n = max(1, frames_in_window)
                print(
                    f"\nBitrate: {measured_kbps:7.1f} kbps | FPS: {fps:4.1f} | "
                    f"Q-scale: {old_qscale:.2f} -> {Q_SCALE:.2f} | PSNR: {psnr:5.2f} dB"
                )
                print(
                    f"Stage timing (avg/frame): capture {t_capture/n*1000:6.1f} ms | "
                    f"encode(motion+DCT) {t_encode/n*1000:6.1f} ms | "
                    f"pack {t_pack/n*1000:6.1f} ms | send {t_send/n*1000:6.1f} ms"
                )
                t_capture = t_encode = t_pack = t_send = 0.0
                bytes_in_window = 0
                frames_in_window = 0
                last_stats_time = now

            print(
                f"\rFrame {frame_id:6d} | {frame_label}-frame | "
                f"Size {sent_bytes / 1000:7.2f} kB | PSNR {psnr:5.2f} dB | Q {Q_SCALE:.2f}",
                end="",
            )

            if SHOW_PREVIEW:
                preview = np.clip(reconstruction, 0, 255).astype(np.uint8)
                cv2.imshow("Compressed Preview", preview)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break

            frame_id = (frame_id + 1) % 1000000
            next_time += interval
            sleep_time = next_time - time.perf_counter()
            if sleep_time > 0:
                time.sleep(sleep_time)
            else:
                next_time = time.perf_counter()

    finally:
        picam2.stop()
        sock.close()
        if SHOW_PREVIEW:
            cv2.destroyAllWindows()
        print("\nSender stopped.")


if __name__ == "__main__":
    main()
