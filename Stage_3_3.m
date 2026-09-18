%% 
% *3.3 Stage 3 : Improved hybrid video codec (out of 105%)*
% 
% 3.3.1 Optimize the quantisation process of the codec to facilitate transmission 
% in fixed bandwidth environment. You may use an optimisation analysis to find 
% the best QP to meet the given bit-rate. 

%% =========== 3.3.2 Stage 3: Optimized Hybrid Video Codec ========================
% Advanced Rate-Distortion Optimization for Fixed Bandwidth (608 kbps)
% Features: Fixed 480x272 Res, Fast ME, Intra/Inter Decision, Per-Frame QF Binary Search

clear; clc; close all;

%% 1. Video Loading & Target Setup
video_path = 'video 3 (1080p).mp4';
v = VideoReader(video_path);

output_path = 'reconstructed_video_max_opt.mp4';
v_out = VideoWriter(output_path, 'MPEG-4');
v_out.FrameRate = v.FrameRate; 
open(v_out);

% Bandwidth Budgeting
target_kbps = 608; 
fps = v.FrameRate;
total_frames = v.NumFrames;
total_budget_bits = total_frames * (target_kbps * 1000) / fps;

fprintf('=== STAGE 3.3.2: MAXIMUM QUALITY RATE CONTROL ===\n');
fprintf('Target Bandwidth : %d kbps\n', target_kbps);
fprintf('Target Resolution: 480 x 272\n');
fprintf('Total Bit Budget : %.0f bits for entire video\n\n', total_budget_bits);

% Codec Parameters
MB_size = 16;
search_range = 8;
block_size = 8;

% Fixed Target Resolution (Width=480, Height=272)
% 480 and 272 are perfectly divisible by 16, so padding is 0.
target_H = 272; 
target_W = 480;

Q50 = [16 11 10 16 24 40 51 61;
       12 12 14 19 26 58 60 55;
       14 13 16 24 40 57 69 56;
       14 17 22 29 51 87 80 62;
       18 22 37 56 68 109 103 77;
       24 35 55 64 81 104 113 92;
       49 64 78 87 103 121 120 101;
       72 92 95 98 112 100 103 99];
zigzagIdx = zigzagIndices(block_size);

%% 2. Video Processing with Per-Frame QF Binary Search
total_bits_video = 0;
total_psnr_video = 0;
frame_count = 0;
remaining_budget = total_budget_bits;

% For PSNR calculation against true original
v.CurrentTime = 0; 
first_frame = double(rgb2gray(readFrame(v)));
[orig_H, orig_W] = size(first_frame);
v.CurrentTime = 0; % Reset for main loop

% Initialize variable to track the sum of all QFs
total_qf_video = 0;
while hasFrame(v)
    frame_count = frame_count + 1;
    frame_gray = double(rgb2gray(readFrame(v)));
    
    % Force resolution to exactly 480x272
    current_frame = imresize(frame_gray, [target_H, target_W], 'bilinear');
    [Hp, Wp] = size(current_frame);
    
    % Calculate exact bit budget for THIS frame based on remaining video budget
    frames_left = total_frames - frame_count + 1;
    frame_target_bits = remaining_budget / frames_left;
    
    % Variables to hold the best QF search results
    lo_qf = 1; hi_qf = 100;
    best_qf = 1; best_bits = inf;
    best_bs = []; best_hd = {}; best_bd = [];
    valid_found = false;
    
    if frame_count == 1
        %% INTRA-PREDICTION (I-Frame)
        % Binary Search for the optimal QF for this specific I-Frame
        while lo_qf <= hi_qf
            test_qf = floor((lo_qf + hi_qf) / 2);
            Qmat_test = buildQuantMatrix(Q50, test_qf);
            
            [bs_test, hd_test, bd_test, ~] = encodeImage(current_frame, Qmat_test, block_size, zigzagIdx);
            test_bits = numel(bs_test);
            
            if test_bits <= frame_target_bits
                valid_found = true;
                best_qf = test_qf;
                best_bits = test_bits;
                best_bs = bs_test; best_hd = hd_test; best_bd = bd_test;
                lo_qf = test_qf + 1; % Try to push quality higher
            else
                hi_qf = test_qf - 1; % Exceeded limit, drop quality
            end
        end
        
        % Safety fallback if even QF=1 is too big
        if ~valid_found
            best_qf = 1;
            Qmat_opt = buildQuantMatrix(Q50, 1);
            [best_bs, best_hd, best_bd, ~] = encodeImage(current_frame, Qmat_opt, block_size, zigzagIdx);
            best_bits = numel(best_bs);
        end
        
        % Decode the optimal version for reference
        Qmat_final = buildQuantMatrix(Q50, best_qf);
        rec_frame = decodeImage(best_bs, best_hd, Qmat_final, block_size, zigzagIdx, best_bd);
        ref_frame = rec_frame;
        
    else
        %% INTER-PREDICTION (P-Frame)
        % 1. Motion Estimation & Decision Block (Done ONCE per frame)
        predicted_frame = zeros(Hp, Wp);
        MVs = zeros(Hp/MB_size, Wp/MB_size, 2); 
        mb_modes = zeros(Hp/MB_size, Wp/MB_size); % 0=Intra, 1=Inter
        
        for r = 1 : MB_size : Hp
            for c = 1 : MB_size : Wp
                target_MB = current_frame(r:r+MB_size-1, c:c+MB_size-1);
                
                % Fast Logarithmic Search
                center_y = r; center_x = c; step_size = floor(search_range / 2);
                while step_size >= 1
                    min_SAD = inf; best_step_y = center_y; best_step_x = center_x;
                    for i = -1:1
                        for j = -1:1
                            test_y = center_y + i * step_size; test_x = center_x + j * step_size;
                            if test_y >= 1 && test_y <= (Hp - MB_size + 1) && test_x >= 1 && test_x <= (Wp - MB_size + 1)
                                ref_MB = ref_frame(test_y:test_y+MB_size-1, test_x:test_x+MB_size-1);
                                SAD = sum(abs(target_MB(:) - ref_MB(:)));
                                if SAD < min_SAD
                                    min_SAD = SAD; best_step_y = test_y; best_step_x = test_x;
                                end
                            end
                        end
                    end
                    center_y = best_step_y; center_x = best_step_x; step_size = floor(step_size / 2);
                end
                
                % Intra vs Inter Decision Block
                SAD_inter = min_SAD;
                SAD_intra = sum(abs(target_MB(:) - 128)); 
                
                mb_row = floor((r-1)/MB_size)+1; mb_col = floor((c-1)/MB_size)+1;
                if SAD_inter < SAD_intra - 300 
                    mb_modes(mb_row, mb_col) = 1; 
                    MVs(mb_row, mb_col, :) = [center_y - r, center_x - c];
                    predicted_frame(r:r+MB_size-1, c:c+MB_size-1) = ref_frame(center_y:center_y+MB_size-1, center_x:center_x+MB_size-1);
                else
                    mb_modes(mb_row, mb_col) = 0; 
                    MVs(mb_row, mb_col, :) = [0, 0];
                    predicted_frame(r:r+MB_size-1, c:c+MB_size-1) = 128; 
                end
            end
        end
        
        residual = current_frame - predicted_frame;
        shifted_residual = residual + 128; 
        
        % Fixed overhead bits (MVs + Modes)
        overhead_bits = (sum(mb_modes(:) == 1) * 8) + numel(mb_modes);
        
        % 2. Binary Search for QF specifically for this P-Frame residual
        while lo_qf <= hi_qf
            test_qf = floor((lo_qf + hi_qf) / 2);
            Qmat_test = buildQuantMatrix(Q50, test_qf);
            
            [bs_test, hd_test, bd_test, ~] = encodeImage(shifted_residual, Qmat_test, block_size, zigzagIdx);
            test_bits = numel(bs_test) + overhead_bits;
            
            if test_bits <= frame_target_bits
                valid_found = true;
                best_qf = test_qf;
                best_bits = test_bits;
                best_bs = bs_test; best_hd = hd_test; best_bd = bd_test;
                lo_qf = test_qf + 1; % Try higher quality
            else
                hi_qf = test_qf - 1; % Exceeded budget, lower quality
            end
        end
        
        % Safety fallback
        if ~valid_found
            best_qf = 1;
            Qmat_opt = buildQuantMatrix(Q50, 1);
            [best_bs, best_hd, best_bd, ~] = encodeImage(shifted_residual, Qmat_opt, block_size, zigzagIdx);
            best_bits = numel(best_bs) + overhead_bits;
        end
        
        % 3. Reconstruct Optimal Frame
        Qmat_final = buildQuantMatrix(Q50, best_qf);
        decoded_shifted = decodeImage(best_bs, best_hd, Qmat_final, block_size, zigzagIdx, best_bd);
        rec_residual = decoded_shifted - 128;
        rec_frame = predicted_frame + rec_residual;
        ref_frame = rec_frame;
    end
    
    %% 3. UPDATE BUDGETS & METRICS
    total_bits_video = total_bits_video + best_bits;
    remaining_budget = remaining_budget - best_bits;
    
    % Upsample to 1080p to calculate PSNR and save video
    rec_frame_final = imresize(rec_frame, [orig_H, orig_W], 'bilinear');
    final_img_uint8 = uint8(min(max(rec_frame_final, 0), 255));
    
    writeVideo(v_out, repmat(final_img_uint8, 1, 1, 3));
    
    frame_psnr = psnrCalc(uint8(frame_gray), final_img_uint8);
    total_psnr_video = total_psnr_video + frame_psnr;
    % Add the current frame's QF to the total
    total_qf_video = total_qf_video + best_qf;
    
    % Print Per-Frame Analysis
    fprintf('Frame %03d | Used %5.0f bits (Max Allowed: %5.0f) | Opt QF: %02.0f | Rem. Budget: %7.0f | PSNR: %5.2f dB\n', ...
        frame_count, best_bits, frame_target_bits, best_qf, remaining_budget, frame_psnr);
end

close(v_out);

%% 4. Final Metrics
actual_kbps = (total_bits_video / frame_count) * fps / 1000;
avg_psnr_final = total_psnr_video / frame_count;

fprintf('\n=== HIGH-QUALITY BUDGET CODEC COMPLETE ===\n');
fprintf('Total Frames Processed : %d\n', frame_count);
fprintf('Target Bandwidth       : %d kbps\n', target_kbps);
fprintf('Achieved Bandwidth     : %.2f kbps\n', actual_kbps);
fprintf('Average PSNR           : %.2f dB\n', avg_psnr_final);
fprintf('Saved Video As         : %s\n', output_path);
% Calculate the average
avg_qf_final = total_qf_video / frame_count;

% Print the result along with your other metrics
fprintf('Average QF             : %.2f\n', avg_qf_final);


%% ================= LOCAL FUNCTIONS  =================

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
    
    % SAFETY FIX: Prevent huffmandict error if symbol stream has only 1 unique value
    if length(unique(symbolStream)) < 2
        symbolStream = [symbolStream, 9999]; % Append a dummy symbol
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
    
    % Remove dummy safety symbol if it was added during encoding
    symbolStream(symbolStream == 9999) = [];
    
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
% 3.3.2 Optimise the coding process to give the best bit-rate for a given quality 
% level. Your implementation should use a decision block to select either Intra 
% or Inter prediction for each coding block. It should have a feedback loop from 
% the expected output quality to the quantisation and the prediction stage to 
% analyse the performance on the fly

%% =========== 3.3.2 Stage 3: Fixed Quality & Minimum Bitrate ========================
% Optimizes the coding process to give the best (lowest) bit-rate for a given Quality Level
% Features: Intra/Inter Decision Block & Performance Feedback Loop

fprintf('\n=== STAGE 3.3.2: FIXED QUALITY OPTIMIZATION ===\n');

%% 1. Target Setup
video_path = 'video 3 (1080p).mp4';
v = VideoReader(video_path);

output_path = 'reconstructed_video_fixed_quality.mp4';
v_out = VideoWriter(output_path, 'MPEG-4');
v_out.FrameRate = v.FrameRate; 
open(v_out);

% Fixed Target Resolution (to maintain fast processing)
target_H = 272; 
target_W = 480;

% Codec Parameters
MB_size = 16;
search_range = 8;
block_size = 8;

% User Requested Quality Level
baseline_qf = 20; 
current_qf = baseline_qf; 
target_psnr = 0; % Will be dynamically calibrated on Frame 1

Q50 = [16 11 10 16 24 40 51 61;
       12 12 14 19 26 58 60 55;
       14 13 16 24 40 57 69 56;
       14 17 22 29 51 87 80 62;
       18 22 37 56 68 109 103 77;
       24 35 55 64 81 104 113 92;
       49 64 78 87 103 121 120 101;
       72 92 95 98 112 100 103 99];
zigzagIdx = zigzagIndices(block_size);

%% 2. Video Processing with Quality Feedback Loop
total_bits_fixed_q = 0;
total_psnr_fixed_q = 0;
frame_count = 0;

% For true PSNR calculation
first_frame = double(rgb2gray(readFrame(v)));
[orig_H, orig_W] = size(first_frame);
v.CurrentTime = 0; % Reset for main loop

fprintf('Target Baseline QF: %d\n', baseline_qf);
fprintf('Processing video to minimize bit-rate while maintaining target quality...\n\n');

while hasFrame(v)
    frame_count = frame_count + 1;
    frame_gray = double(rgb2gray(readFrame(v)));
    
    current_frame = imresize(frame_gray, [target_H, target_W], 'bilinear');
    [Hp, Wp] = size(current_frame);
    
    % Update Quantization Matrix based on Feedback Loop
    Qmat = buildQuantMatrix(Q50, round(current_qf));
    
    if frame_count == 1
        %% INTRA-PREDICTION (I-Frame)
        [bs, hd, bd, ~] = encodeImage(current_frame, Qmat, block_size, zigzagIdx);
        frame_bits = numel(bs);
        rec_frame = decodeImage(bs, hd, Qmat, block_size, zigzagIdx, bd);
        ref_frame = rec_frame;
        
        % Calibrate Target PSNR based on requested QF=20
        rec_frame_final = imresize(rec_frame, [orig_H, orig_W], 'bilinear');
        final_img_uint8 = uint8(min(max(rec_frame_final, 0), 255));
        target_psnr = psnrCalc(uint8(frame_gray), final_img_uint8);
        frame_psnr = target_psnr;
        
        fprintf('>>> Calibration Complete: Locked Target PSNR at %.2f dB <<<\n\n', target_psnr);
        
    else
        %% INTER-PREDICTION (P-Frame)
        predicted_frame = zeros(Hp, Wp);
        MVs = zeros(Hp/MB_size, Wp/MB_size, 2); 
        mb_modes = zeros(Hp/MB_size, Wp/MB_size); % 0=Intra, 1=Inter
        
        for r = 1 : MB_size : Hp
            for c = 1 : MB_size : Wp
                target_MB = current_frame(r:r+MB_size-1, c:c+MB_size-1);
                
                % Fast Logarithmic Search
                center_y = r; center_x = c; step_size = floor(search_range / 2);
                while step_size >= 1
                    min_SAD = inf; best_step_y = center_y; best_step_x = center_x;
                    for i = -1:1
                        for j = -1:1
                            test_y = center_y + i * step_size; test_x = center_x + j * step_size;
                            if test_y >= 1 && test_y <= (Hp - MB_size + 1) && test_x >= 1 && test_x <= (Wp - MB_size + 1)
                                ref_MB = ref_frame(test_y:test_y+MB_size-1, test_x:test_x+MB_size-1);
                                SAD = sum(abs(target_MB(:) - ref_MB(:)));
                                if SAD < min_SAD
                                    min_SAD = SAD; best_step_y = test_y; best_step_x = test_x;
                                end
                            end
                        end
                    end
                    center_y = best_step_y; center_x = best_step_x; step_size = floor(step_size / 2);
                end
                
                %% DECISION BLOCK: Select Intra or Inter
                SAD_inter = min_SAD;
                SAD_intra = sum(abs(target_MB(:) - 128)); 
                
                mb_row = floor((r-1)/MB_size)+1; mb_col = floor((c-1)/MB_size)+1;
                
                if SAD_inter < SAD_intra - 300 
                    mb_modes(mb_row, mb_col) = 1; % INTER is cheaper
                    MVs(mb_row, mb_col, :) = [center_y - r, center_x - c];
                    predicted_frame(r:r+MB_size-1, c:c+MB_size-1) = ref_frame(center_y:center_y+MB_size-1, center_x:center_x+MB_size-1);
                else
                    mb_modes(mb_row, mb_col) = 0; % INTRA is cheaper
                    MVs(mb_row, mb_col, :) = [0, 0];
                    predicted_frame(r:r+MB_size-1, c:c+MB_size-1) = 128; 
                end
            end
        end
        
        residual = current_frame - predicted_frame;
        shifted_residual = residual + 128; 
        
        [bs, hd, bd, ~] = encodeImage(shifted_residual, Qmat, block_size, zigzagIdx);
        
        overhead_bits = (sum(mb_modes(:) == 1) * 8) + numel(mb_modes);
        frame_bits = numel(bs) + overhead_bits;
        
        decoded_shifted = decodeImage(bs, hd, Qmat, block_size, zigzagIdx, bd);
        rec_residual = decoded_shifted - 128;
        rec_frame = predicted_frame + rec_residual;
        ref_frame = rec_frame;
        
        % Calculate PSNR for Feedback
        rec_frame_final = imresize(rec_frame, [orig_H, orig_W], 'bilinear');
        final_img_uint8 = uint8(min(max(rec_frame_final, 0), 255));
        frame_psnr = psnrCalc(uint8(frame_gray), final_img_uint8);
        
        %% FEEDBACK LOOP: Expected Quality -> Quantization Stage
        % If PSNR is too high -> We are wasting bits. Lower QF (increase QP).
        % If PSNR is too low -> We lost quality. Raise QF (decrease QP).
        
        psnr_error = target_psnr - frame_psnr; 
        
        % Adjustment factor (Multiplier dictates how aggressively it corrects)
        qf_adjustment = psnr_error * 3.5; 
        current_qf = current_qf + qf_adjustment; 
        
        % Clamp QF strictly between limits to prevent matrix errors
        current_qf = max(2, min(current_qf, 95));
    end
    
    total_bits_fixed_q = total_bits_fixed_q + frame_bits;
    total_psnr_fixed_q = total_psnr_fixed_q + frame_psnr;
    
    % Write to video file
    if frame_count > 1
        writeVideo(v_out, repmat(final_img_uint8, 1, 1, 3));
    else
        writeVideo(v_out, repmat(final_img_uint8, 1, 1, 3));
    end
    
    % Print Per-Frame Analysis
    fprintf('Frame %03d | Used %6.0f bits | Dynamic QF: %02.0f | Output PSNR: %5.2f dB\n', ...
        frame_count, frame_bits, current_qf, frame_psnr);
end

close(v_out);

%% 3. Final Metrics
final_kbps = (total_bits_fixed_q / frame_count) * v.FrameRate / 1000;
avg_psnr_out = total_psnr_fixed_q / frame_count;

fprintf('\n=== FIXED QUALITY VIDEO COMPRESSION COMPLETE ===\n');
fprintf('Total Frames Processed : %d\n', frame_count);
fprintf('Target Quality (PSNR)  : %.2f dB\n', target_psnr);
fprintf('Average Achieved PSNR  : %.2f dB\n', avg_psnr_out);
fprintf('Optimized Bit-rate     : %.2f kbps\n', final_kbps);
fprintf('Saved Video As         : %s\n', output_path);