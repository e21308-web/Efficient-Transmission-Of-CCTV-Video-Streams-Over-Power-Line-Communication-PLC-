import socket
import struct
import time

import cv2
import numpy as np

# ============================================================
# PC VIDEO RECEIVER - handles both wire formats motion_sender.py
# can produce:
#   b"VC33" -> Huffman-coded symbols (FAST_MODE = False)
#   b"VC34" -> fixed-width int16 symbols, no entropy coding (FAST_MODE = True)
# It auto-detects which one arrived from the 4-byte magic, so you
# don't need to keep the two files' FAST_MODE flag in sync.
# ============================================================

RECV_IP = "0.0.0.0"
RECV_PORT = 5005

MB = 16
N = 8

MAX_PACKET = 65535
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


def idct2_batch(D):
    return np.matmul(np.matmul(DCT_T.T, D), DCT_T)


def assemble_tiles(tiles, rows, cols, tile):
    return tiles.reshape(rows, cols, tile, tile).transpose(0, 2, 1, 3).reshape(rows * tile, cols * tile)


def merge_sub_to_mb(sub_blocks, num_mb):
    return sub_blocks.reshape(num_mb, 2, 2, 8, 8).transpose(0, 1, 3, 2, 4).reshape(num_mb, 16, 16)


def unpack_huffman(data, position):
    number_of_symbols = struct.unpack_from("!H", data, position)[0]
    position += 2
    lengths = {}
    for _ in range(number_of_symbols):
        symbol, length = struct.unpack_from("!iB", data, position)
        position += 5
        lengths[int(symbol)] = int(length)

    padding, number_of_bytes = struct.unpack_from("!BI", data, position)
    position += 5
    raw = data[position:position + number_of_bytes]
    position += number_of_bytes

    items = sorted(lengths.items(), key=lambda x: (x[1], x[0]))
    code = 0
    previous_length = 0
    decode_table = {}
    for symbol, length in items:
        code <<= (length - previous_length)
        decode_table[(code, length)] = symbol
        code += 1
        previous_length = length

    bits = ''.join(format(byte, "08b") for byte in raw)
    if padding:
        bits = bits[:-padding]

    values = []
    acc = 0
    length = 0
    for bit in bits:
        acc = (acc << 1) | (1 if bit == "1" else 0)
        length += 1
        key = (acc, length)
        if key in decode_table:
            values.append(decode_table[key])
            acc = 0
            length = 0

    return values, position


def unpack_fixed(data, position, count):
    arr = np.frombuffer(data, dtype=">i2", count=count, offset=position)
    return arr.astype(np.int64).tolist(), position + count * 2


def _residual_from_symbols(all_symbols, Q, rows, cols):
    num_mb = rows * cols
    symbols_array = np.array(all_symbols, dtype=np.float32).reshape(-1, 64)

    dc_diffs = symbols_array[:, 0]
    dc_vals = np.cumsum(dc_diffs)
    coefficients = symbols_array.copy()
    coefficients[:, 0] = dc_vals

    reordered = np.zeros_like(coefficients)
    reordered[:, ZIGZAG_ARR] = coefficients
    Dq = reordered.reshape(-1, 8, 8) * Q
    recon_sub = idct2_batch(Dq)
    recon_mb = merge_sub_to_mb(recon_sub, num_mb)
    return assemble_tiles(recon_mb, rows, cols, MB)


def decode_i_frame(all_symbols, width, height, qscale):
    Q = build_quant_matrix(23, qscale)
    rows, cols = height // MB, width // MB
    residual = _residual_from_symbols(all_symbols, Q, rows, cols)
    return np.clip(residual, 0, 255)


def decode_p_frame(all_symbols, motion_vectors, width, height, qscale, previous_reconstruction):
    Q = build_quant_matrix(23, qscale)
    rows, cols = height // MB, width // MB

    compensated = np.empty((height, width), dtype=np.float32)
    idx = 0
    for r in range(0, height, MB):
        for c in range(0, width, MB):
            dy, dx = motion_vectors[idx]
            idx += 1
            ref_r = int(np.clip(r + dy, 0, height - MB))
            ref_c = int(np.clip(c + dx, 0, width - MB))
            compensated[r:r + MB, c:c + MB] = previous_reconstruction[ref_r:ref_r + MB, ref_c:ref_c + MB]

    residual = _residual_from_symbols(all_symbols, Q, rows, cols)
    return np.clip(compensated + residual, 0, 255)


def parse_and_reconstruct(compressed_data, previous_reconstruction):
    magic = compressed_data[:4]
    if magic not in (b"VC33", b"VC34"):
        raise ValueError("Invalid compressed frame.")
    fast_mode = magic == b"VC34"

    position = 4
    width, height, frame_type, qscale, psnr, number_of_macroblocks = struct.unpack_from(
        "!HHBffH", compressed_data, position
    )
    position += struct.calcsize("!HHBffH")

    if frame_type == 0:
        num_symbols = number_of_macroblocks * 4 * 64
        if fast_mode:
            symbols, _ = unpack_fixed(compressed_data, position, num_symbols)
        else:
            symbols, _ = unpack_huffman(compressed_data, position)
        reconstruction = decode_i_frame(symbols, width, height, qscale)
        frame_name = "I"

    elif frame_type == 1:
        if previous_reconstruction is None:
            raise ValueError("P-frame received without a reference I-frame.")

        motion_vectors = []
        for _ in range(number_of_macroblocks):
            dy, dx = struct.unpack_from("!bb", compressed_data, position)
            position += 2
            motion_vectors.append((int(dy), int(dx)))

        num_symbols = number_of_macroblocks * 4 * 64
        if fast_mode:
            symbols, _ = unpack_fixed(compressed_data, position, num_symbols)
        else:
            symbols, _ = unpack_huffman(compressed_data, position)
        reconstruction = decode_p_frame(symbols, motion_vectors, width, height, qscale, previous_reconstruction)
        frame_name = "P"

    else:
        raise ValueError(f"Unknown frame type: {frame_type}")

    return reconstruction, frame_name, psnr, qscale


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((RECV_IP, RECV_PORT))
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sock.settimeout(0.2)

    pending = {}
    previous_reconstruction = None

    total_received_bytes = 0
    window_start = time.perf_counter()
    frame_count = 0

    print()
    print("==============================================")
    print("   PC VIDEO RECEIVER (motion estimation)")
    print("==============================================")
    print(f"Listening       : {RECV_IP}:{RECV_PORT}")
    print("Auto-detects Huffman (VC33) or fixed-width (VC34) frames")
    print("==============================================")
    print()

    try:
        while True:
            try:
                packet, _ = sock.recvfrom(MAX_PACKET)
            except socket.timeout:
                continue

            if len(packet) < HEADER.size:
                continue

            frame_id, chunk_index, total_chunks, frame_type, qbyte = HEADER.unpack(packet[:HEADER.size])
            payload = packet[HEADER.size:]
            total_received_bytes += len(payload)

            if frame_id not in pending:
                pending[frame_id] = {"total": total_chunks, "chunks": {}}
            pending[frame_id]["chunks"][chunk_index] = payload
            info = pending[frame_id]

            if len(info["chunks"]) == info["total"]:
                compressed_data = b"".join(info["chunks"][i] for i in range(info["total"]))

                try:
                    reconstruction, frame_name, psnr, qscale = parse_and_reconstruct(
                        compressed_data, previous_reconstruction
                    )
                    previous_reconstruction = reconstruction
                    frame_count += 1

                    display = np.clip(reconstruction, 0, 255).astype(np.uint8)
                    cv2.imshow("Receiver - Reconstructed Video", display)

                    now = time.perf_counter()
                    if now - window_start >= 1.0:
                        elapsed = now - window_start
                        bitrate_kbps = total_received_bytes * 8.0 / 1000.0 / elapsed
                        fps = frame_count / elapsed
                        print(f"\nRX bitrate: {bitrate_kbps:7.1f} kbps | FPS: {fps:4.1f}")
                        total_received_bytes = 0
                        frame_count = 0
                        window_start = now

                    print(
                        f"\rFrame {frame_id:6d} | {frame_name}-frame | "
                        f"PSNR {psnr:5.2f} dB | Q {qscale:.2f}",
                        end="",
                    )

                    if cv2.waitKey(1) & 0xFF == ord("q"):
                        break

                except Exception as error:
                    print(f"\nFrame {frame_id} decode error: {error}")
                    previous_reconstruction = None

                del pending[frame_id]

            stale = [key for key in pending if key < frame_id - 20]
            for key in stale:
                del pending[key]

    finally:
        sock.close()
        cv2.destroyAllWindows()
        print("\nReceiver stopped.")


if __name__ == "__main__":
    main()
