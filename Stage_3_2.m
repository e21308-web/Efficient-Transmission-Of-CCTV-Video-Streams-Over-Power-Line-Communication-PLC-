%% 
% *3.2 Stage 2: Basic implementation 2 : Video compression (out of 70%)*
% 
% Improve the system designed at stage 3.1 to support video compression. You 
% may use macro block based coding, basic motion estimation and intra prediction

%% =========== 3.2 Stage 2: Basic Video Compression ========================
% Hybrid Video Codec using Fast Logarithmic Search (Three-Step Search)
% Processes 1080p frames and saves to output .mp4.

clear; clc; close all;

%% 1. Video Loading and Output Setup
video_path = 'video 3 (1080p).mp4';
v = VideoReader(video_path);

% Setup VideoWriter to save the reconstructed output
output_path = 'reconstructed_video_logsearch.mp4';
v_out = VideoWriter(output_path, 'MPEG-4');
v_out.FrameRate = v.FrameRate; % Keep original 30fps
open(v_out);

% Compression Parameters
MB_size = 16;            % 16x16 Macroblock for Motion Estimation
search_range = 8;        % Search window [-8, +8]
block_size = 8;          % 8x8 block for DCT (from Stage 3.1)
QF = 50;                 % Standard Quality Factor

% 3.1 Standard JPEG luminance matrix
Q50 = [16 11 10 16 24 40 51 61;
       12 12 14 19 26 58 60 55;
       14 13 16 24 40 57 69 56;
       14 17 22 29 51 87 80 62;
       18 22 37 56 68 109 103 77;
       24 35 55 64 81 104 113 92;
       49 64 78 87 103 121 120 101;
       72 92 95 98 112 100 103 99];
       
Qmat = buildQuantMatrix(Q50, QF);
zigzagIdx = zigzagIndices(block_size);

%% 2. Hybrid Video Encoder / Decoder Loop
total_bits = 0;
total_psnr = 0;
frame_idx = 0;

fprintf('Starting Full Video Compression using Fast Logarithmic Search...\n');

while hasFrame(v)
    frame_idx = frame_idx + 1;
    
    % Read and convert frame to grayscale
    frame_rgb = readFrame(v);
    frame_gray = double(rgb2gray(frame_rgb));
    [H, W] = size(frame_gray);
    
    % Pad to ensure dimensions are multiples of Macroblock size (16x16)
    padH = mod(MB_size - mod(H, MB_size), MB_size);
    padW = mod(MB_size - mod(W, MB_size), MB_size);
    current_frame = padarray(frame_gray, [padH padW], 'replicate', 'post');
    [Hp, Wp] = size(current_frame);
    
    fprintf('Processing Frame %d... ', frame_idx);
    
    if frame_idx == 1
        %% INTRA-PREDICTION (I-Frame)
        fprintf('(I-Frame) -> ');
        
        % 1. Encode using unmodified 3.1 logic
        [bs, hd, bd, ~] = encodeImage(current_frame, Qmat, block_size, zigzagIdx);
        total_bits = total_bits + numel(bs);
        
        % 2. Decode to act as the reference frame for the next frame
        rec_frame = decodeImage(bs, hd, Qmat, block_size, zigzagIdx, bd);
        
        % Store Reference
        ref_frame = rec_frame;
        
    else
        %% INTER-PREDICTION (P-Frame)
        fprintf('(P-Frame) -> ');
        
        % 1. Motion Estimation (Fast Logarithmic Search)
        predicted_frame = zeros(Hp, Wp);
        MVs = zeros(Hp/MB_size, Wp/MB_size, 2); 
        
        for r = 1 : MB_size : Hp
            for c = 1 : MB_size : Wp
                % Target Macroblock in current frame
                target_MB = current_frame(r:r+MB_size-1, c:c+MB_size-1);
                
                % Fast Log Search Variables
                center_y = r;
                center_x = c;
                best_dy = 0; 
                best_dx = 0;
                step_size = floor(search_range / 2); % Initial step size (e.g., 4)
                
                % Search loop (reduces step size by half each iteration)
                while step_size >= 1
                    min_SAD = inf;
                    best_step_y = center_y;
                    best_step_x = center_x;
                    
                    % Check the 9 points around the current center
                    for i = -1:1
                        for j = -1:1
                            test_y = center_y + i * step_size;
                            test_x = center_x + j * step_size;
                            
                            % Ensure search point is within frame boundaries
                            if test_y >= 1 && test_y <= (Hp - MB_size + 1) && ...
                               test_x >= 1 && test_x <= (Wp - MB_size + 1)
                                
                                ref_MB = ref_frame(test_y:test_y+MB_size-1, test_x:test_x+MB_size-1);
                                SAD = sum(abs(target_MB(:) - ref_MB(:)));
                                
                                if SAD < min_SAD
                                    min_SAD = SAD;
                                    best_step_y = test_y;
                                    best_step_x = test_x;
                                end
                            end
                        end
                    end
                    
                    % Move the center to the point with the lowest SAD
                    center_y = best_step_y;
                    center_x = best_step_x;
                    
                    % Halve the step size for the next logarithmic pass
                    step_size = floor(step_size / 2);
                end
                
                % Save Final Motion Vector
                best_dy = center_y - r;
                best_dx = center_x - c;
                
                mb_row = floor((r-1)/MB_size) + 1;
                mb_col = floor((c-1)/MB_size) + 1;
                MVs(mb_row, mb_col, 1) = best_dy;
                MVs(mb_row, mb_col, 2) = best_dx;
                
                % Build Predicted Frame
                predicted_frame(r:r+MB_size-1, c:c+MB_size-1) = ref_frame(r+best_dy:r+best_dy+MB_size-1, c+best_dx:c+best_dx+MB_size-1);
            end
        end
        
        % 2. Calculate Residual
        residual = current_frame - predicted_frame;
        
        % 3. Encode Residual 
        % TRICK: We add 128 so the unmodified 3.1 encodeImage (which subtracts 128) handles it correctly
        shifted_residual = residual + 128;
        [bs, hd, bd, ~] = encodeImage(shifted_residual, Qmat, block_size, zigzagIdx);
        
        % Add bits (Residual bits + Motion Vectors)
        mv_bits = numel(MVs) * 8;
        total_bits = total_bits + numel(bs) + mv_bits;
        
        % 4. Decode Residual
        decoded_shifted = decodeImage(bs, hd, Qmat, block_size, zigzagIdx, bd);
        rec_residual = decoded_shifted - 128; % Remove the trick offset
        
        % 5. Reconstruct Frame = Prediction + Decoded Residual
        rec_frame = predicted_frame + rec_residual;
        
        % Update Reference for next frame
        ref_frame = rec_frame;
    end
    
    % Unpad the frame to original 1080p size
    rec_frame_unpad = rec_frame(1:H, 1:W);
    
    % Ensure limits are respected and write to video file
    final_img_uint8 = uint8(min(max(rec_frame_unpad, 0), 255));
    
    % Write grayscale as 3-channel RGB so VideoWriter handles it natively
    writeVideo(v_out, repmat(final_img_uint8, 1, 1, 3));
    
    % Calculate and display PSNR for this frame
    frame_psnr = psnrCalc(uint8(frame_gray), final_img_uint8);
    total_psnr = total_psnr + frame_psnr;
    
    fprintf('PSNR = %.2f dB\n', frame_psnr);
end

% Close Video Writer
close(v_out);

%% 3. Final Metrics
avg_psnr = total_psnr / frame_idx;
original_bits = H * W * 8 * frame_idx;
compression_ratio = original_bits / total_bits;

fprintf('\n=== FAST LOGARITHMIC VIDEO COMPRESSION COMPLETE ===\n');
fprintf('Total Frames Processed : %d\n', frame_idx);
fprintf('Total Compressed Size  : %.2f MB\n', (total_bits/8)/(1024*1024));
fprintf('Overall Compression    : %.2f:1\n', compression_ratio);
fprintf('Average PSNR           : %.2f dB\n', avg_psnr);
fprintf('Saved to               : %s\n', output_path);


%% ================= LOCAL FUNCTIONS (UNMODIFIED FROM 3.1) =================

function Qmat = buildQuantMatrix(Q50, QF)
    if QF < 50
        S = 5000 / QF;
    else
        S = 200 - 2*QF;
    end
    Qmat = floor((S * Q50 + 50) / 100);
    Qmat(Qmat < 1) = 1;
    Qmat(Qmat > 255) = 255;
end

function idx = zigzagIndices(N)
    M = zeros(N,N);
    val = 1;
    for s = 0:(2*N-2)
        if mod(s,2) == 0
            r = min(s,N-1):-1:max(0,s-N+1);
            c = s - r;
        else
            c = min(s,N-1):-1:max(0,s-N+1);
            r = s - c;
        end
        for t = 1:length(r)
            M(r(t)+1, c(t)+1) = val;
            val = val + 1;
        end
    end
    [~, idx] = sort(M(:));
end

function [bitstream, huffDict, blockDims, symbolStream] = encodeImage(I_pad, Qmat, bs, zigzagIdx)
    [Hp, Wp] = size(I_pad);
    nBR = Hp/bs; nBC = Wp/bs;
    blockDims = [nBR, nBC];
    I_shift = I_pad - 128;
    symbolStream = [];
    for br = 1:nBR
        for bc = 1:nBC
            block = I_shift((br-1)*bs+1:br*bs, (bc-1)*bs+1:bc*bs);
            D = dct2(block);
            Qb = round(D ./ Qmat);
            zz = Qb(zigzagIdx);
            rle = runLengthEncode(zz);
            symbolStream = [symbolStream, rle]; 
        end
    end
    [symbols, ~, ic] = unique(symbolStream);
    counts = accumarray(ic(:), 1);
    probs = counts / sum(counts);
    huffDict = huffmandict(symbols, probs);
    bitstream = huffmanenco(symbolStream, huffDict);
end

function I_rec = decodeImage(bitstream, huffDict, Qmat, bs, zigzagIdx, blockDims)
    nBR = blockDims(1); nBC = blockDims(2);
    Hp = nBR*bs; Wp = nBC*bs;
    symbolStream = huffmandeco(bitstream, huffDict);
    I_rec = zeros(Hp, Wp);
    ptr = 1;
    for br = 1:nBR
        for bc = 1:nBC
            [zz, ptr] = runLengthDecode(symbolStream, ptr, bs*bs);
            Qb = zeros(bs,bs);
            Qb(zigzagIdx) = zz;
            D = Qb .* Qmat;
            block = idct2(D) + 128;
            I_rec((br-1)*bs+1:br*bs, (bc-1)*bs+1:bc*bs) = block;
        end
    end
end

function rle = runLengthEncode(zz)
    rle = [];
    run = 0;
    N = length(zz);
    lastNZ = find(zz~=0, 1, 'last');
    if isempty(lastNZ)
        rle = [0, 0]; 
        return;
    end
    for i = 1:lastNZ
        if zz(i) == 0
            run = run + 1;
        else
            rle = [rle, run, zz(i)]; 
            run = 0;
        end
    end
    rle = [rle, 0, 0]; 
end

function [zz, ptr] = runLengthDecode(symbolStream, ptr, blockLen)
    zz = zeros(1, blockLen);
    pos = 1;
    while true
        run = symbolStream(ptr);
        val = symbolStream(ptr+1);
        ptr = ptr + 2;
        if run == 0 && val == 0
            break; 
        end
        pos = pos + run;
        zz(pos) = val;
        pos = pos + 1;
    end
end

function p = psnrCalc(orig, rec)
    orig = double(orig); rec = double(rec);
    mse = mean((orig(:)-rec(:)).^2);
    if mse == 0
        p = Inf;
    else
        p = 10 * log10(255^2 / mse);
    end
end
%%
% 1. Video Loading and Setup
% Calculate total uncompressed bits
% 8 bits per pixel for Grayscale (the format your codec uses)
uncompressed_bits_gray = vidWidth * vidHeight * 8 * numFrames;
% 24 bits per pixel for raw RGB Color (for reference)
uncompressed_bits_rgb = vidWidth * vidHeight * 24 * numFrames;

% Print the original video size, bits, and details
fprintf('\n=== ORIGINAL VIDEO DETAILS ===\n');
fprintf('Resolution             : %d x %d pixels\n', vidWidth, vidHeight);
fprintf('Total Frames           : %d\n', numFrames);
fprintf('Frame Rate             : %.2f fps\n', framerate);
fprintf('Total Bits (Grayscale) : %d bits (%.2f MB)\n', uncompressed_bits_gray, uncompressed_bits_gray / (8 * 1024 * 1024));
fprintf('Total Bits (RGB Color) : %d bits (%.2f MB)\n\n', uncompressed_bits_rgb, uncompressed_bits_rgb / (8 * 1024 * 1024));