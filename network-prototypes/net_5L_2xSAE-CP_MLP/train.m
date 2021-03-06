clear ; close all; clc % cleanup
%%======================================================================
%% Configuration
%  ! Setup and check all parameters before run

datasetDir = 'C:/Develop/_n4j-nn-data/dataset-30_400_200_x7/'; % dataset root dir
trainSetCSVFile = 'coin.tr.shuffled.csv'; % this file will be generated from 'coin.tr.csv'

unlabeledImgDir = 'img_unlabeled/'; % sub directory with images for auto-encoder training (unlabeled/for unsupervised feature extraction)
imgDir = 'img_grayscale/'; % sub directory with images
tempDir = 'temp/'; % for pooled features used with mini batch

% configs are in separate file to easy share between train.m / test.m
config;

fprintf(' Parameters for L2  \n');
cnn{1}
fprintf(' Parameters for L3  \n');
cnn{2}

% show matrix size transformation between layers
fprintf('\nL1 -> L2  (%u X %u X %u) -> (%u X %u X %u) / (%u -> %u) \n', cnn{1}.inputWidth, cnn{1}.inputHeight, cnn{1}.inputChannels, cnn{1}.outputWidth, cnn{1}.outputHeight, cnn{1}.outputChannels, ...
                                        cnn{1}.inputWidth * cnn{1}.inputHeight * cnn{1}.inputChannels, cnn{1}.outputWidth * cnn{1}.outputHeight * cnn{1}.outputChannels);
                                    
fprintf('\nL2 -> L3  (%u X %u X %u) -> (%u X %u X %u) / (%u -> %u) \n', cnn{2}.inputWidth, cnn{2}.inputHeight, cnn{2}.inputChannels, cnn{2}.outputWidth, cnn{2}.outputHeight, cnn{2}.outputChannels, ...
                                        cnn{2}.inputWidth * cnn{2}.inputHeight * cnn{2}.inputChannels, cnn{2}.outputWidth * cnn{2}.outputHeight * cnn{2}.outputChannels);

fprintf('\nL3 -> L4  %u -> %u \n', cnn{2}.outputWidth * cnn{2}.outputHeight * cnn{2}.outputChannels, inputSizeL5);

fprintf('\nL4 -> L5  %u -> %u \n', inputSizeL5, numOutputClasses);

%% Initializatoin

% create suffled training set - if doesn't created
if ~exist(strcat(datasetDir, 'coin.tr.shuffled.csv'), 'file')
    fprintf('Generating shuffled training set coin.tr.shuffled.csv from coin.tr.csv \n');
    shuffleTrainingSet(datasetDir, 'coin.tr.csv', 'coin.tr.shuffled.csv');
end

mkdir(strcat(datasetDir, tempDir)); % create temp dir - if doesn't exist


csvdata = csvread(strcat(datasetDir, trainSetCSVFile));    
sampleId = csvdata(:, 1); % first column is sampleId (imageIdx)
y = csvdata(:, 2); % second column is coinIdx
m = size(csvdata, 1); % amount of training examples
batchIterationCount = ceil(m / batchSize);

%% Visualize some full size images from training set
% make sure visualy we work on the right dataset

visualAmount = 3^2;
fprintf('Visualize %u full size images ...\n', visualAmount);
[previewX] = loadImageSet(csvdata(1:visualAmount, 1), strcat(datasetDir, imgDir), imgW, imgH);
fullSizeImages = zeros(imgW^2, visualAmount);
for i = 1:visualAmount
    % visualization works for squared matrixes
    % before visualization convert img_h x img_w -> img_w * img_w
    fullSizeImages(:, i) = resizeImage2Square(previewX(:, i), imgW, imgH);
end;

display_network(fullSizeImages);

clear previewX fullSizeImages;

fprintf(' Program is paused. Press ENTER to continue  \n');
pause;

%%======================================================================

%% L2 training (patches extraction, SAE training, convelution & pooling)
fprintf('\nL2 training (patches extraction, SAE training, convelution & pooling) ... (%u X %u X %u) -> (%u X %u X %u) \n', cnn{1}.inputWidth, cnn{1}.inputHeight, cnn{1}.inputChannels, cnn{1}.outputWidth, cnn{1}.outputHeight, cnn{1}.outputChannels);

%% L2 Patches for auto-encoders training
fprintf('\nL2 - patches extraction for SAE training ...\n')
saeL2PatchesFile = strcat(datasetDir, tempDir, 'L2_PATCHES.mat');
if exist(saeL2PatchesFile, 'file')
    % PATCHES.mat file exists. 
    fprintf('Loading patches for sparse auto-encoder training from %s  \n', saeL2PatchesFile);
    load(saeL2PatchesFile);
else
    % PATCHES.mat File does not exist. do generation
    fprintf('Cant load patches for sparse auto-encoder training from %s  \n', saeL2PatchesFile);
    fprintf('  Do patch geenration \n');
    
    unlabeledImgDirFullPath = strcat(datasetDir, unlabeledImgDir); % dir with unlabeled images
    unlabeledImgFiles = dir(fullfile(unlabeledImgDirFullPath, '*.jpg')); % img files
    fprintf('Loading %u random images for patches ...\n', length(unlabeledImgFiles));
    unlabeledImagesX = zeros(imgW*imgH, length(unlabeledImgFiles)); % unlabeled images
    % loop over files and load images into matrix
    for idx = 1:length(unlabeledImgFiles)
        gImg = imread([unlabeledImgDirFullPath unlabeledImgFiles(idx).name]);
        imgV = reshape(gImg, 1, imgW*imgH); % unroll       
        unlabeledImagesX(:, idx) = imgV; 
    end
    
    fprintf('Generating %u patches (%u x %u) from images ...\n', cnn{1}.numPatches, cnn{1}.patchSize, cnn{1}.patchSize);
    [patches, meanPatchL2] = getPatches(unlabeledImagesX, cnn{1}.inputWidth, cnn{1}.inputHeight, cnn{1}.patchSize, cnn{1}.numPatches);

    % remove (clean up some memory)
    clear shuffledX

    save(saeL2PatchesFile, 'patches', 'meanPatchL2');
    display_network(patches(:,randi(size(patches,2),200,1)));
    fprintf('Patches generation complete ...\n');
end

%%======================================================================
%% L2 SAE training
fprintf('\nL2 SAE training ...\n');

if exist(strcat(datasetDir, tempDir, 'L2_SAE_FEATURES.mat'), 'file')
    % SAE1_FEATURES.mat file exists. 
    fprintf('Loading sparse auto-encoder features from %s  \n', strcat(datasetDir, tempDir, 'L2_SAE_FEATURES.mat'));    
    load(strcat(datasetDir, tempDir, 'L2_SAE_FEATURES.mat'));
else
    % SAE1_FEATURES.mat File does not exist. do generation
    fprintf('Cant load sparse auto-encoder features from %s  \n', strcat(datasetDir, tempDir, 'L2_SAE_FEATURES.mat'));
    fprintf('  Do features extraction \n');
    
    %  Obtain random parameters theta
    theta = saeMatrixInit(cnn{1}.features, cnn{1}.inputVisibleSize);

    [sae2OptTheta, cost] = minFunc( @(p) sparseAutoencoderCost(p, ...
                                       cnn{1}.inputVisibleSize, cnn{1}.features, ...
                                       saeLambda, saeSparsityParam, ...
                                       saeBeta, patches), ...
                                       theta, saeOptions);

    save(strcat(datasetDir, tempDir, 'L2_SAE_FEATURES.mat'), 'sae2OptTheta', 'meanPatchL2');
end

% Visualization Sparser Autoencoder Features to see that the features look good
W = reshape(sae2OptTheta(1:cnn{1}.inputVisibleSize * cnn{1}.features), cnn{1}.features, cnn{1}.inputVisibleSize);

display_network(W'); % L2

clear patches 
%%======================================================================
%% L2 - Convolution & pooling
fprintf('\n L2 - Feedforward with SAE L2, Convolve & pool ...\n')

for batchIter = 1 : batchIterationCount

    startPosition = (batchIter - 1) * batchSize + 1;
    endPosition = startPosition + batchSize - 1;
    if endPosition > m
        endPosition = m;
    end

    fprintf('\n Convolved and pooled (CP) L2 feature extraction: batch sub-iteration (%u / %u): start %u end %u from %u training samples \n', batchIter, batchIterationCount, startPosition, endPosition, m);        
    %%------ cache convolved and pooled features - will be used in next layers ----------        
    pooledFeaturesTempFile = strcat(datasetDir, tempDir, 'L2_CP_FEATURES_', num2str(batchIter), '.mat');
    if ~exist(pooledFeaturesTempFile, 'file')
        % File does not exist - do convolution and pooling
        fprintf('\nNo file with pooled features for iteration %u. Do convolution and pooling ... \n', batchIter);
        [shuffledX] = loadImageSet(sampleId(startPosition:endPosition), strcat(datasetDir, imgDir), imgW, imgH);
        
        % feedforward using sae2OptTheta, convolve and pool
        cpFeaturesL2 = convolveAndPool(shuffledX, sae2OptTheta, cnn{1}.features, ...
                                        cnn{1}.inputHeight, cnn{1}.inputWidth, cnn{1}.inputChannels, ...
                                        cnn{1}.patchSize, meanPatchL2, cnn{1}.poolSize, ...
                                        convolutionsStepSize);
        save(pooledFeaturesTempFile, 'cpFeaturesL2');
    end
    %%----------------------------------------------------------------------------------        
end; % for batchIter = 1 : batchIterationCount

%%======================================================================
%% L3 training (patches extraction, SAE training, convelution & pooling)
fprintf('\nL3 training (patches extraction, SAE training, convelution & pooling) ... (%u X %u X %u) -> (%u X %u X %u) \n', cnn{2}.inputWidth, cnn{2}.inputHeight, cnn{2}.inputChannels, cnn{2}.outputWidth, cnn{2}.outputHeight, cnn{2}.outputChannels);


%% L3 Patches for auto-encoders training
fprintf('\nL3 - patches extraction for SAE training ...\n')
saeL3PatchesFile = strcat(datasetDir, tempDir, 'L3_PATCHES.mat');

if exist(saeL3PatchesFile, 'file')
    % PATCHES.mat file exists. 
    fprintf('Loading patches for sparse auto-encoder training from %s  \n', saeL3PatchesFile);
    load(saeL3PatchesFile);
else
    % PATCHES.mat File does not exist. do generation
    fprintf('Cant load patches for sparse auto-encoder training from %s  \n', saeL3PatchesFile);
    fprintf('  Do patch geenration \n');
    
    numPatches = floor(cnn{2}.numPatches / batchIterationCount); % get some patches from every batch iteration

    for batchIter = 1 : batchIterationCount
        %load cpFeaturesL2
        cpFeaturesL2File = strcat(datasetDir, tempDir, 'L2_CP_FEATURES_', num2str(batchIter), '.mat');
        load(cpFeaturesL2File);
        % Reshape cpFeaturesL2 
        numTrainImages = size(cpFeaturesL2, 2);
        outL2 = permute(cpFeaturesL2, [4 3 1 2]); % W x H x Ch x tr_num
        [patchesThis, meanPatchL3This] = getPatches2(outL2, cnn{2}.patchSize, numPatches);
                
        if 1 == batchIter
            patches = patchesThis;
            meanPatchL3 = meanPatchL3This;
        else 
            patches = [patches patchesThis];
            meanPatchL3 = [meanPatchL3 meanPatchL3This];
        end

    end; % for batchIter = 1 : batchIterationCount
    meanPatchL3 = mean(meanPatchL3, 2);

    save(saeL3PatchesFile, 'patches', 'meanPatchL3');
    display_network(patches(:,randi(size(patches,2),200,1)));
    fprintf('Patches generation complete ...\n');
end
%%======================================================================
%% L3 SAE training
fprintf('\nL3 SAE training ...\n');

if exist(strcat(datasetDir, tempDir, 'L3_SAE_FEATURES.mat'), 'file')
    % SAE1_FEATURES.mat file exists. 
    fprintf('Loading sparse auto-encoder features from %s  \n', strcat(datasetDir, tempDir, 'L3_SAE_FEATURES.mat'));    
    load(strcat(datasetDir, tempDir, 'L3_SAE_FEATURES.mat'));
else
    % SAE1_FEATURES.mat File does not exist. do generation
    fprintf('Cant load sparse auto-encoder features from %s  \n', strcat(datasetDir, tempDir, 'L3_SAE_FEATURES.mat'));
    fprintf('  Do features extraction \n');
    
    %  Obtain random parameters theta
    theta = saeMatrixInit(cnn{2}.features, cnn{2}.inputVisibleSize);

    [sae3OptTheta, cost] = minFunc( @(p) sparseAutoencoderCost(p, ...
                                       cnn{2}.inputVisibleSize, cnn{2}.features, ...
                                       saeLambda, saeSparsityParam, ...
                                       saeBeta, patches), ...
                                  theta, saeOptions);

    save(strcat(datasetDir, tempDir, 'L3_SAE_FEATURES.mat'), 'sae3OptTheta', 'meanPatchL3');
end
    
% Visualization Sparser Autoencoder Features to see that the features look good
W = reshape(sae3OptTheta(1 : cnn{2}.inputVisibleSize * cnn{2}.features), cnn{2}.features, cnn{2}.inputVisibleSize);

%display_network(W'); % L3

%pause;
%%======================================================================
%% L3 - Convolution & pooling
fprintf('\n L3 - Feedforward with SAE L3, Convolve & pool ...\n')

for batchIter = 1 : batchIterationCount

    startPosition = (batchIter - 1) * batchSize + 1;
    endPosition = startPosition + batchSize - 1;
    if endPosition > m
        endPosition = m;
    end

    fprintf('\n Convolved and pooled (CP) L3 feature extraction: batch sub-iteration (%u / %u): start %u end %u from %u training samples \n', batchIter, batchIterationCount, startPosition, endPosition, m);        
    %%------ cache convolved and pooled features - will be used in next layers ----------        
    pooledFeaturesTempFile = strcat(datasetDir, tempDir, 'L3_CP_FEATURES_', num2str(batchIter), '.mat');
    if ~exist(pooledFeaturesTempFile, 'file')
        % File does not exist - do convolution and pooling
        fprintf('\nNo file with pooled features for iteration %u. Do convolution and pooling ... \n', batchIter);
        %load cpFeaturesL2
        cpFeaturesL2File = strcat(datasetDir, tempDir, 'L2_CP_FEATURES_', num2str(batchIter), '.mat');
        load(cpFeaturesL2File);
        % Reshape cpFeaturesL2 
        numTrainImages = size(cpFeaturesL2, 2);
        outL2 = permute(cpFeaturesL2, [4 3 1 2]); % W x H x Ch x tr_num
        
        shuffledX = reshape(outL2, cnn{1}.outputSize, numTrainImages);
        
        % feedforward using sae2OptTheta, convolve and pool
        cpFeaturesL3 = convolveAndPool(shuffledX, sae3OptTheta, cnn{2}.features, ...
                                        cnn{2}.inputHeight, cnn{2}.inputWidth, cnn{2}.inputChannels, ...
                                        cnn{2}.patchSize, meanPatchL3, cnn{2}.poolSize, ...
                                        convolutionsStepSize);
        save(pooledFeaturesTempFile, 'cpFeaturesL3');
    end
    %%----------------------------------------------------------------------------------        
end; % for batchIter = 1 : batchIterationCount

        
%% L4 L5 (MLP) Training
fprintf('\nL4 L5 (MLP) Training ... \n')

mlpInputLayerSize = inputSizeL4;
mlpHiddenLayerSize = inputSizeL5;
        
theta4File = strcat(datasetDir, tempDir, 'L4_THETA.mat');
if exist(theta4File, 'file')
    % L4_THETA.mat file exists. 
    fprintf('Loading Thetta4 from %s  \n', theta4File);
    load(theta4File);
    initial_Theta4 = Theta4;  
else
    % File does not exist. random initialization
    fprintf('Cant load Thetta4 from %s  \n  Do random initialization for Thetta1 \n', theta4File);
    initial_Theta4 = mlpMatrixLayerInit(mlpInputLayerSize, mlpHiddenLayerSize);
end

theta5File = strcat(datasetDir, tempDir, 'L5_THETA.mat');
if exist(theta5File, 'file')
    % L5_THETA.mat file exists. 
    fprintf('Loading Thetta5 from %s  \n', theta5File);
    load(theta5File);
    initial_Theta5 = Theta5;  
else
    % File does not exist. random initialization
    fprintf('Cant load Thetta5 from %s  \n  Do random initialization for Thetta2 \n', theta5File);
    initial_Theta5 = mlpMatrixLayerInit(mlpHiddenLayerSize, numOutputClasses);
end

fprintf('Theta4: %u x %u \n', size(initial_Theta4, 2), size(initial_Theta4, 1));
fprintf('Theta5: %u x %u \n', size(initial_Theta5, 2), size(initial_Theta5, 1));
%----- end load Thettas -------------------

% Unroll parameters
nn_params = [initial_Theta4(:) ; initial_Theta5(:)];

costs = zeros(numTrainIterL4L5, 1); % cost func over training iterations

for trainingIter = 1 : numTrainIterL4L5 % loop over training iterations
    fprintf('\nStarting training iteration %u from %u \n', trainingIter, numTrainIterL4L5);
    % loop over batches (training examples)
    
    iterCost = 0;
    for batchIter = 1 : batchIterationCount

        startPosition = (batchIter - 1) * batchSize + 1;
        endPosition = startPosition + batchSize - 1;
        if endPosition > m
            endPosition = m;
        end

        fprintf('\n training iteration (%u / %u): batch sub-iteration (%u / %u): start %u end %u from %u training samples \n', trainingIter, numTrainIterL4L5, batchIter, batchIterationCount, startPosition, endPosition, m);
        
        % loads cpFeaturesL3
        load(strcat(datasetDir, tempDir, 'L3_CP_FEATURES_', num2str(batchIter), '.mat')); % file must exist from previous iterations
        
        % Reshape the pooledFeatures to form an input vector for softmax
        X = permute(cpFeaturesL3, [4 3 1 2]); % W x H x Ch x tr_num
        numTrainImages = size(cpFeaturesL3, 2);
        X = reshape(X, inputSizeL4, numTrainImages);
  
        [nn_params, cost] = minFunc( @(p) mlpCost(p, ...
                                                mlpInputLayerSize, ...
                                                mlpHiddenLayerSize, ...
                                                numOutputClasses, X, y(startPosition:endPosition), mlpLambda), ...
                                    nn_params, mlpOptions);
                          
        % save thetas - can be used if training cycle interrupted 
        Theta4 = reshape(nn_params(1:(mlpInputLayerSize + 1) * mlpHiddenLayerSize), (mlpInputLayerSize + 1), mlpHiddenLayerSize);
        Theta5 = reshape(nn_params((1 + (mlpInputLayerSize + 1) * mlpHiddenLayerSize):end), (mlpHiddenLayerSize + 1), numOutputClasses);
        save(theta4File, 'Theta4');
        save(theta5File, 'Theta5');
        
        iterCost = iterCost + cost;
    end; % for batchIter = 1 : batchIterationCount
    iterCost = iterCost/batchIterationCount;
    costs(trainingIter) = iterCost;
        
    fprintf('\nIteration %4i done - softmaxTheta saved. Average Cost is %4.4f \n', trainingIter, iterCost);

%-------- debug info ------------    
    figure(2);
    xlabel('Training iterations');
    ylabel('Cost function');
    title('Cost function over training iterations');
    plot(costs);
%-------- debug info ------------    
end; % for trainingIter = 1 : trainingIterationCount % loop over training iterations

fprintf('Training complete. \n');
