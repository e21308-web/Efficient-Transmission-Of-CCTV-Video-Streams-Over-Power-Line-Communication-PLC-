%=========================================================
%IMAGE COMPRESSION
% Crop Starting Point : (180,264)
%=========================================================
%% 

clc;
clear;
close all;
%% 
% *Step 1 and 2: Read the original image into a Matrix.* 


%% =======================================================
% STEP 1 : READ ORIGINAL COLOR IMAGE
% =======================================================

img = imread('D:\sem 6\image and video coding\huffman coding lab\sample2.jpeg');

figure;
imshow(img);
title('Original Color Image - E/21/366');

%% =======================================================
% STEP 2 : CONVERT TO GRAYSCALE
% =======================================================

if size(img,3)==3
    imgGray = rgb2gray(img);
else
    imgGray = img;
end

imgGray = double(imgGray);

figure;
imshow(uint8(imgGray));
title('Grayscale Image - E/21/366');
%% 
% *Step 3: Select 16×16 cropped sub-image from your input at step2*


%% =======================================================
% STEP 3 : 16x16 CROP sub-image
% ========================================================

startCol = 180;
startRow = 264;

cropped = imgGray(startRow:startRow+15,...
                  startCol:startCol+15);

figure;
imshow(imresize(uint8(cropped),20,'nearest'));
title('16x16 Cropped Image (20x Enlarged) - E/21/366');

disp(' ');
disp('==============================');
disp('CROPPED IMAGE MATRIX');
disp('==============================');
disp(cropped);

writematrix(cropped,'cropped_matrix.csv');
%% 
% *Step 4: Quantize the output at Step 3 into 8 levels (level 0-7) using uniform 
% quantization.*  

%% =======================================================
% STEP 4 : QUANTIZATION (8 LEVELS)
% ========================================================

quantized = floor(cropped/32);

quantized(quantized>7)=7;

figure;
imshow(imresize(uint8(quantized*36),20,'nearest'));
title('Quantized Image (20x Enlarged)- E/21/366');

disp(' ');
disp('==============================');
disp('QUANTIZED MATRIX');
disp('==============================');
disp(quantized);

writematrix(quantized,'quantized_matrix.csv');
%% 
% *Step 5: Find the probability of each symbol distribution of the output at 
% Step 4.* 

%% =======================================================
% STEP 5 : PROBABILITY DISTRIBUTION
% ========================================================

symbols = 0:7;

counts = zeros(1,8);

for i=1:8
    counts(i)=sum(quantized(:)==symbols(i));
end

prob = counts/sum(counts);

T = table(symbols',counts',prob',...
    'VariableNames',...
    {'Symbol','Count','Probability'});

disp(' ');
disp('==============================');
disp('PROBABILITY DISTRIBUTION');
disp('==============================');
disp(T);

writetable(T,'probability_distribution.csv');

figure;
stem(symbols,prob,'filled');
grid on;
xlabel('Symbol');
ylabel('Probability');
title('Probability Distribution');
%% 
% *Step 6: Construct the Huffman coding algorithm for cropped image at Step 
% 4.*

%% =======================================================
% STEP 6 : MANUAL HUFFMAN CODING
% =======================================================

valid = prob > 0;

symbols_huff = symbols(valid);
prob_huff = prob(valid);

codebook = buildHuffman(prob_huff,symbols_huff);

disp(' ');
disp('==============================');
disp('HUFFMAN CODEBOOK');
disp('==============================');

fid = fopen('codebook.txt','w');

for i=1:length(codebook)

    fprintf('Symbol %d : %s\n',...
        codebook(i).symbol,...
        codebook(i).code);

    fprintf(fid,...
        'Symbol %d : %s\n',...
        codebook(i).symbol,...
        codebook(i).code);

end

fclose(fid);

%% =======================================================
% AVERAGE CODE LENGTH
% ========================================================

avgLength = 0;

for i=1:length(codebook)

    idx = find(symbols_huff == codebook(i).symbol);

    avgLength = avgLength + ...
        prob_huff(idx)*length(codebook(i).code);

end

fprintf('\nAverage Length = %.4f bits/symbol\n',...
    avgLength);
%% 
% *Step 7: Compress both cropped and original images using the algorithm and 
% the codebook  generated at step 6. You may round any intensity values outside 
% the codebook, to the nearest  intensity value in the codebook, where necessary.*


%% =======================================================
% STEP 7 : COMPRESS CROPPED IMAGE
% ========================================================

croppedStream = '';

for k=1:numel(quantized)

    s = quantized(k);

    idx = find([codebook.symbol]==s);

    croppedStream = strcat(...
        croppedStream,...
        codebook(idx).code);

end
%% =======================================================
% DECOMPRESS CROPPED IMAGE
% =======================================================

decodedCrop = decodeCustom( ...
    croppedStream,...
    codebook,...
    numel(quantized));

decodedCrop = reshape( ...
    decodedCrop,...
    size(quantized));

reconstructedCrop = ...
    uint8(decodedCrop*32);

figure;
imshow( ...
    imresize(reconstructedCrop,...
    20,'nearest'));

title('Reconstructed Cropped Image');

%% =======================================================
% COMPRESS ORIGINAL IMAGE
% ========================================================
imgQuant = floor(imgGray/32);

imgQuant(imgQuant>7)=7;

originalStream = '';

availableSymbols = [codebook.symbol];

for k=1:numel(imgQuant)

    s = imgQuant(k);

    if ~ismember(s,availableSymbols)

        [~,idxNearest] = ...
            min(abs(availableSymbols-s));

        s = availableSymbols(idxNearest);

    end

    idx = find(availableSymbols==s);

    originalStream = strcat(...
        originalStream,...
        codebook(idx).code);

end
%% 
% *Step 8: Save the compressed image into a text file.* 


%% =======================================================
% STEP 8 : SAVE CUSTOM COMPRESSED DATA
% ========================================================

fid = fopen('compressed_custom.txt','w');
fprintf(fid,'%s',originalStream);
fclose(fid);

disp('Custom compressed file saved.');

%% =======================================================
% CROPPED COMPRESSION RATIO
% ========================================================

croppedOriginalBits = numel(cropped)*8;

croppedCompressedBits = length(croppedStream);

CR_cropped = ...
    croppedOriginalBits/croppedCompressedBits;

fprintf('\nCompression Ratio (Cropped) = %.4f\n',...
    CR_cropped);
%% 
% *Step 9: Compress the original image using Huffman encoding function in the 
% Matlab tool box and  save it into                        another text file*


%% =======================================================
% STEP 9 : MATLAB BUILT-IN HUFFMAN
% ========================================================

dict = huffmandict(symbols_huff,prob_huff);
imgQuant_builtin = imgQuant;

availableSymbols = symbols_huff;

for k = 1:numel(imgQuant_builtin)

    s = imgQuant_builtin(k);

    if ~ismember(s,availableSymbols)

        [~,idxNearest] = ...
            min(abs(availableSymbols-s));

        imgQuant_builtin(k) = ...
            availableSymbols(idxNearest);

    end

end
encoded_builtin = ...
    huffmanenco(imgQuant_builtin(:),dict);

fid = fopen('compressed_builtin.txt','w');

fprintf(fid,'%d ',encoded_builtin);

fclose(fid);

disp('Built-in compressed file saved.');

%% =======================================================
% ORIGINAL IMAGE COMPRESSION RATIOS
% ========================================================

originalBits = numel(imgGray)*8;

customBits = length(originalStream);

builtinBits = length(encoded_builtin);

CR_custom = originalBits/customBits;

CR_builtin = originalBits/builtinBits;

fprintf('\nCompression Ratio (Original-Custom) = %.4f\n',...
    CR_custom);

fprintf('Compression Ratio (Original-BuiltIn) = %.4f\n',...
    CR_builtin);
%% 
% *Step 10: Decompress the outputs at Step 8 and 9, by reading in the text files.*

%% =======================================================
% STEP 10 : DECOMPRESSION
% ========================================================

decodedCustom = ...
    decodeCustom(originalStream,...
    codebook,...
    numel(imgQuant));

decodedCustom = ...
    reshape(decodedCustom,...
    size(imgQuant));

reconstructed = uint8(decodedCustom*32);

figure;
imshow(reconstructed);
title('Reconstructed Image (Custom)');

decoded_builtin = ...
    huffmandeco(encoded_builtin,dict);

decoded_builtin = ...
    reshape(decoded_builtin,...
    size(imgQuant));

reconstructed_builtin = ...
    uint8(decoded_builtin*32);

figure;
imshow(reconstructed_builtin);
title('Reconstructed Image (Built-In)');
%% 
% *Step 11: Calculate the entropy of the Source*

%% =======================================================
% STEP 11 : ENTROPY
% ========================================================

entropyCrop = 0;

for i=1:length(prob)

    if prob(i)~=0
        entropyCrop = ...
            entropyCrop - prob(i)*log2(prob(i));
    end

end

fprintf('\nEntropy (Cropped) = %.4f bits\n',...
    entropyCrop);

[countOrig,~] = imhist(uint8(imgGray));

pOrig = countOrig/sum(countOrig);

entropyOrig = 0;

for i=1:length(pOrig)

    if pOrig(i)~=0
        entropyOrig = ...
            entropyOrig - pOrig(i)*log2(pOrig(i));
    end

end

fprintf('Entropy (Original) = %.4f bits\n',...
    entropyOrig);

[countDec,~] = imhist(reconstructed);

pDec = countDec/sum(countDec);

entropyDec = 0;

for i=1:length(pDec)

    if pDec(i)~=0
        entropyDec = ...
            entropyDec - pDec(i)*log2(pDec(i));
    end

end

fprintf('Entropy (Decompressed) = %.4f bits\n',...
    entropyDec);
%% 
% *Step 12: Evaluate the PSNR of The original images  and The decompressed images* 

%% =======================================================
% STEP 12 : PSNR
% ========================================================

mseCustom = mean(...
    (imgGray(:)-double(reconstructed(:))).^2);

psnrCustom = ...
    10*log10(255^2/mseCustom);

fprintf('\nPSNR (Custom) = %.4f dB\n',...
    psnrCustom);

mseBuiltin = mean(...
    (imgGray(:)-double(reconstructed_builtin(:))).^2);

psnrBuiltin = ...
    10*log10(255^2/mseBuiltin);

fprintf('PSNR (Built-In) = %.4f dB\n',...
    psnrBuiltin);
%% =======================================================
% PSNR OF CROPPED IMAGE
% =======================================================

mseCrop = mean( ...
    (cropped(:)-double(reconstructedCrop(:))).^2);

if mseCrop == 0
    psnrCrop = Inf;
else
    psnrCrop = 10*log10(255^2/mseCrop);
end

fprintf('\nPSNR (Cropped Image) = %.4f dB\n',...
    psnrCrop);

disp(' ');
disp('========================================');
disp('PROGRAM COMPLETED SUCCESSFULLY');
disp('========================================');
%% 
% Although Huffman coding is lossless, the PSNR is finite because the image 
% was quantized before encoding. The distortion is introduced by quantization, 
% not by the Huffman encoder/decoder. If the reconstructed image is compared with 
% the quantized image, the MSE becomes zero and the PSNR becomes infinite.


%% =======================================================
% LOCAL FUNCTION 1
% MANUAL HUFFMAN TREE CONSTRUCTION
% ========================================================

function codebook = buildHuffman(prob,symbols)

valid = prob > 0;

prob = prob(valid);
symbols = symbols(valid);

nodes = {};

for i=1:length(prob)

    node.prob = prob(i);
    node.symbol = symbols(i);
    node.left = [];
    node.right = [];

    nodes{end+1}=node;

end

while length(nodes)>1

    p = zeros(length(nodes),1);

    for i=1:length(nodes)
        p(i)=nodes{i}.prob;
    end

    [~,idx] = sort(p);

    nodes = nodes(idx);

    leftNode = nodes{1};
    rightNode = nodes{2};

    newNode.prob = ...
        leftNode.prob + rightNode.prob;

    newNode.symbol = [];

    newNode.left = leftNode;
    newNode.right = rightNode;

    nodes = [{newNode} nodes(3:end)];

end

root = nodes{1};

codes = {};

generateCodes(root,'');

for i=1:length(codes)

    codebook(i).symbol = codes{i,1};
    codebook(i).code = codes{i,2};

end

    function generateCodes(node,str)

        if isempty(node.left) && ...
           isempty(node.right)

            codes(end+1,:) = ...
                {node.symbol,str};

            return

        end

        generateCodes(node.left,[str '0']);
        generateCodes(node.right,[str '1']);

    end

end

%% =======================================================
% LOCAL FUNCTION 2
% HUFFMAN DECODER
% ========================================================

function decoded = ...
    decodeCustom(bitstream,...
    codebook,...
    totalSymbols)

decoded = zeros(totalSymbols,1);

buffer = '';

count = 1;

for i=1:length(bitstream)

    buffer = [buffer bitstream(i)];

    for j=1:length(codebook)

        if strcmp(buffer,...
                codebook(j).code)

            decoded(count)=...
                codebook(j).symbol;

            count = count + 1;

            buffer='';

            break

        end

    end

    if count>totalSymbols
        break
    end

end

end