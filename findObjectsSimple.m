%% ObjectFinder - Recognize 3D structures in image stacks
%  Copyright (C) 2016,2017,2018 Luca Della Santina
%
%  This file is part of ObjectFinder
%
%  ObjectFinder is free software: you can redistribute it and/or modify
%  it under the terms of the GNU General Public License as published by
%  the Free Software Foundation, either version 3 of the License, or
%  (at your option) any later version.
%
%  This program is distributed in the hope that it will be useful,
%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%  GNU General Public License for more details.
%
%  You should have received a copy of the GNU General Public License
%  along with this program.  If not, see <https://www.gnu.org/licenses/>.
%
% *Find objects using a single thresholding aware of local noise*

function Dots = findObjectsSimple(Post, Settings)

% Retrieve parameters to use from Settings
blockSize        = Settings.objfinder.blockSize;
blockBuffer      = Settings.objfinder.blockBuffer;
thresholdStep    = Settings.objfinder.thresholdStep;
maxDotSize       = Settings.objfinder.maxDotSize;
minDotSize       = Settings.objfinder.minDotSize;
blockSearch      = Settings.objfinder.blockSearch;
minIntensity     = Settings.objfinder.minIntensity;

% Calculate the block size to Subsample the volume
if blockSearch
    if size(Post,2)>blockSize
        NumBx=round(size(Post,2)/blockSize);
        Bxc=fix(size(Post,2)/NumBx);
    else
        NumBx=1;
        Bxc=size(Post,2);
    end
    
    if size(Post,1)>blockSize
        NumBy=round(size(Post,1)/blockSize);
        Byc=fix(size(Post,1)/NumBy);
    else
        NumBy=1;
        Byc=size(Post,1);
    end
    
    if size(Post,3)>blockSize
        NumBz=round(size(Post,3)/blockSize);
        Bzc=fix(size(Post,3)/NumBz);
    else
        NumBz=1;
        Bzc=size(Post,3);
    end
else
    % Just one block
	NumBx=1;
    NumBy=1;
    NumBz=1;
    Bxc=size(Post,2);
    Byc=size(Post,1);
    Bzc=size(Post,3);
end

%% -- STEP 1: divide the volume into searching blocks for multi-threading
clear Blocks;
tic;
fprintf('Dividing image volume into blocks... ');
Blocks(NumBx * NumBy * NumBz) = struct;

% Split full image (Post) into blocks
for block = 1:(NumBx*NumBy*NumBz)
    [Blocks(block).Bx, Blocks(block).By, Blocks(block).Bz] = ind2sub([NumBx, NumBy, NumBz], block);
    %disp(['current block = Bx:' num2str(Bx) ', By:' num2str(By) ', Bz:' num2str(Bz)]);

    %Find real territory
    Txstart=(Blocks(block).Bx-1)*Bxc+1;
    Tystart=(Blocks(block).By-1)*Byc+1;
    Tzstart=(Blocks(block).Bz-1)*Bzc+1;

    if Byc, Tyend=Blocks(block).By*Byc; else, Tyend=size(Post,1); end
    if Bxc, Txend=Blocks(block).Bx*Bxc; else, Txend=size(Post,2); end
    if Bzc, Tzend=Blocks(block).Bz*Bzc; else, Tzend=size(Post,3); end

    % Find buffered Borders (if last block, extend to image borders)
    yStart                  = Tystart-blockBuffer;
    yStart(yStart<1)        = 1;
    yEnd                    = Tyend+blockBuffer;
    yEnd(yEnd>size(Post,1)) = size(Post,1);
    xStart                  = Txstart-blockBuffer;
    xStart(xStart<1)        = 1;
    xEnd                    = Txend+blockBuffer;
    xEnd(xEnd>size(Post,2)) = size(Post,2);
    zStart                  = Tzstart-blockBuffer;
    zStart(zStart<1)        = 1;
    zEnd                    = Tzend+blockBuffer;
    zEnd(zEnd>size(Post,3)) = size(Post,3);

    % Slice the raw image into the block of interest (Igm)
    Blocks(block).Igm           = Post(yStart:yEnd,xStart:xEnd,zStart:zEnd);
    
    % Search only between max intensity (Gmax) and noise intensity level (Gmode) found in each block
    Blocks(block).Gmode         = mode(Blocks(block).Igm(Blocks(block).Igm>0)); % Most common intensity found in the block (noise level, excluding zero)
    Blocks(block).Gmax          = max(Blocks(block).Igm(:));
    Blocks(block).sizeIgm       = size(Blocks(block).Igm);

    Blocks(block).peakMap       = zeros(Blocks(block).sizeIgm(1),Blocks(block).sizeIgm(2),Blocks(block).sizeIgm(3),'uint8'); % Initialize matrix to map peaks found
    Blocks(block).thresholdMap  = Blocks(block).peakMap; % Initialize matrix to sum passed thresholds

    % Make sure Gmax can be divided by the stepping size of thresholdStep
    if mod(Blocks(block).Gmax, thresholdStep) ~= mod(Blocks(block).Gmode+1, thresholdStep)
        Blocks(block).Gmax      = Blocks(block).Gmax+1;
    end

    Blocks(block).startPos      = [yStart, xStart, zStart]; % Store for later
    Blocks(block).endPos        = [yEnd, xEnd, zEnd];         % Store for later
    Blocks(block).Igl           = [];
    Blocks(block).wsTMLabels    = [];
	Blocks(block).wsLabelList   = [];
	Blocks(block).nLabels       = 0;

end
fprintf([num2str(NumBx*NumBy*NumBz) ' blocks, DONE in ' num2str(toc) ' seconds \n']);
clear xStart xEnd yStart yEnd zStart zEnd T*

%% -- STEP 2: scan volume to find areas above local contrast threshold --
tic;
fprintf('Searching candidate objects using multi-threaded iterarive threshold ... ');

parfor block = 1:(NumBx*NumBy*NumBz)
    % Scan volume to find areas crossing contrast threshold of minIntensity times the local noise
    i=ceil(Blocks(block).Gmode * minIntensity)+1;
        
    % Label all areas in the block (Igl) that crosses the intensity threshold "i"
    %[Igl,labels] = bwlabeln(Igm>i,6); % shorter but slower
    CC = bwconncomp(Blocks(block).Igm > i,6); % 10 percent faster
    labels = CC.NumObjects;
    Blocks(block).Igl = labelmatrix(CC);
    
    if labels == 0
        continue;
    elseif labels <= 1
        labels = 2;
    end
    if labels < 65536
        Blocks(block).Igl=uint16(Blocks(block).Igl);
    end % Reduce bitdepth if possible
    nPixel = hist(Blocks(block).Igl(Blocks(block).Igl>0), 1:labels);
    
    % Find peak location in each labeled object and check object size
    for p=1:labels
        pixelIndex = find(Blocks(block).Igl==p);
        
        if (nPixel(p) < maxDotSize) && (nPixel(p) > 3)
            if sum(Blocks(block).peakMap(pixelIndex))== 0
                % limit one peak (peakIndex) per labeled area (where Igl==p)
                peakValue = max(Blocks(block).Igm(pixelIndex));
                peakIndex = find(Blocks(block).Igl==p & Blocks(block).Igm==peakValue);
                if numel(peakIndex) > 1
                    peakIndex = peakIndex(round(numel(peakIndex)/2));
                end
                Blocks(block).peakMap(peakIndex) = 1;
            end
        else
            Blocks(block).Igl(pixelIndex)=0;
        end
    end
    Blocks(block).thresholdMap(Blocks(block).Igl>0) = Blocks(block).thresholdMap(Blocks(block).Igl>0)+1; % +1 to all voxels that passed this iteration

    Blocks(block).wsTMLabels    = Blocks(block).Igl;                  % wsTMLabels = block volume labeled with same numbers for the voxels that belong to same object
    Blocks(block).wsLabelList   = unique(Blocks(block).wsTMLabels);   % wsLabelList = unique labels list used to label the block volume 
    Blocks(block).nLabels       = numel(Blocks(block).wsLabelList);   % nLabels = number of labels = number of objects detected
end
fprintf(['DONE in ' num2str(toc) ' seconds \n']);

%% -- STEP 3: Find the countour of each dot and split it using watershed if multiple peaks are found within the same dot --

tic;
if Settings.objfinder.watershed
    fprintf('Split multi-peak objects using multi-threaded watershed segmentation ... ');
    use_watershed = true;
else
    fprintf('Watershed DISABLED by user, collecting candidate objects... ');
    use_watershed = false;
end

parfor block = 1:(NumBx*NumBy*NumBz)
    % Scan again all the blocks
    ys = Blocks(block).sizeIgm(1);  % retrieve values
    xs = Blocks(block).sizeIgm(2);  % retrieve values
    zs = Blocks(block).sizeIgm(3);  % retrieve values
    
    wsThresholdMapBin = uint8(Blocks(block).thresholdMap>0);         % binary map of threshold
    wsThresholdMapBinOpen = imdilate(wsThresholdMapBin, ones(3,3,3));% dilate Bin map with a 3x3x3 kernel (dilated perimeter acts like ridges between background and ROIs)
    wsThresholdMapComp = imcomplement(Blocks(block).thresholdMap);   % complement (invert) image. Required because watershed() separate holes, not mountains. imcomplement creates complement using the entire range of the class, so for uint8, 0 becomes 255 and 255 becomes 0, but for double 0 becomes 1 and 255 becomes -254.
    wsTMMod = wsThresholdMapComp.*wsThresholdMapBinOpen;             % Force background outside of dilated region to 0, and leaves walls of 255 between puncta and background.
    
    if use_watershed
        wsTMLabels = watershed(wsTMMod, 6);                          % 6 voxel connectivity watershed, this will fill background with 1, ridges with 0 and puncta with 2,3,4,... in double format
    else
        wsTMMod = Blocks(block).thresholdMap;                        % 6 voxel connectivity without watershed on the original threshold map.        
        wsTMLabels = bwlabeln(wsTMMod,6);
    end
    
    wsBackgroundLabel = mode(double(wsTMLabels(:)));                 % calculate background level
    wsTMLabels(wsTMLabels == wsBackgroundLabel) = 0;                 % seems that sometimes Background can get into puncta... so the next line was not good enough to remove all the background labels.
    wsTMLabels= double(wsTMLabels).*double(wsThresholdMapBin);       % masking out non-puncta voxels, this makes background and dilated voxels to 0. This also prevents trough voxels from being added back somehow with background. HO 6/4/2010
    wsTMLZeros= find(wsTMLabels==0 & Blocks(block).thresholdMap>0);  % find zeros of watersheds inside of thresholdmap (add back the zero ridges in thresholdMap to their most similar neighbors)
    
    if ~isempty(wsTMLZeros) % if exist zeros in the map
        [wsTMLZerosY, wsTMLZerosX, wsTMLZerosZ] = ind2sub(size(Blocks(block).thresholdMap),wsTMLZeros); %6/4/2010 HO
        for j = 1:length(wsTMLZeros) % create a dilated matrix to examine neighbor connectivity around the zero position
            tempZMID =  wsTMLabels(max(1,wsTMLZerosY(j)-1):min(ys,wsTMLZerosY(j)+1), max(1,wsTMLZerosX(j)-1):min(xs,wsTMLZerosX(j)+1), max(1,wsTMLZerosZ(j)-1):min(zs,wsTMLZerosZ(j)+1)); %HO 6/4/2010
            nZeroID = mode(tempZMID(tempZMID~=0)); % find most common neighbor value (watershed) not including zero
            wsTMLabels(wsTMLZeros(j)) = nZeroID;   % re-define zero with new watershed ID (this process will act similar to watershed by making new neighboring voxels feed into the decision of subsequent zero voxels)
        end
    end
    
    wsTMLabels                  = uint16(wsTMLabels);
    wsLabelList                 = unique(wsTMLabels);
    wsLabelList(1)              = []; % Remove background (labeled 0)
    nLabels                     = length(wsLabelList);
    
    Blocks(block).nLabels       = nLabels;     % Store for later
    Blocks(block).wsTMLabels    = wsTMLabels;  % Store for later
    Blocks(block).wsLabelList   = wsLabelList; % Store for later
end
fprintf(['DONE in ' num2str(toc) ' seconds \n']);

%% -- STEP 4: calculate dots properties and store into a struct array --
tic;
fprintf('Accumulating properties for each detected object... ');

tmpDot               = struct;
tmpDot.Pos           = [0,0,0];
tmpDot.Vox.Pos       = [0,0,0];
tmpDot.Vox.Ind       = [0,0,0];
tmpDot.Vol           = 0;
tmpDot.ITMax         = 0;
tmpDot.ItSum         = 0;
tmpDot.Vox.RawBright = 0;
tmpDot.Vox.IT        = 0;
tmpDot.MeanBright    = 0;

%clear tmpDots
%tmpDots(sum([Blocks.nLabels])) = struct(tmpDot); % Preallocate max number of dots
tmpDots = struct(tmpDot);
tmpDotNum = 0;

for block = 1:(NumBx*NumBy*NumBz)
    wsTMLabels  = Blocks(block).wsTMLabels;
    wsLabelList = Blocks(block).wsLabelList;
    nLabels     = Blocks(block).nLabels;
    
    for i = 1:nLabels
        peakIndex = find( (wsTMLabels==wsLabelList(i)) & (Blocks(block).peakMap>0) ); % this line adjusted for watershed HO 6/7/2010
        thresholdPeak = Blocks(block).Igm(peakIndex) / Blocks(block).Gmode; % Calculate ITMax as # times the local noise
        nPeaks = numel(peakIndex);                

        if nPeaks > 1
            % In case of multiple peaks, get the peak with max threshold
            peakIndex = peakIndex(find(thresholdPeak==max(thresholdPeak),1));
            thresholdPeak = max(thresholdPeak);
            nPeaks = numel(peakIndex);
        else
            %disp(['block = ' num2str(block)]);
            %disp(['i = ' num2str(i)]);
            %disp(['peaks  =' num2str(nPeaks)]);
            %disp(['index = ' num2str(peakIndex)]);
            %disp(['threshold = ' num2str(thresholdPeak)]);
        end
        
        if (nPeaks ~=1)
            % If watershed was used there should not be any more object with multiple peaks
            continue;
        end        
        [yPeak, xPeak, zPeak] = ind2sub(Blocks(block).sizeIgm, peakIndex);

        
        % Accumulate only if object size is within minDotSize/maxDotSize
        contourIndex = find(wsTMLabels==wsLabelList(i)); % adjusted for watershed
        
        if (numel(contourIndex) >= minDotSize) && (numel(contourIndex) <= maxDotSize)
            [yContour, xContour, zContour] = ind2sub(Blocks(block).sizeIgm, contourIndex);

            tmpDot.Pos          = [yPeak+Blocks(block).startPos(1)-1,    xPeak+Blocks(block).startPos(2)-1,    zPeak+Blocks(block).startPos(3)-1];
            tmpDot.Vox.Pos      = [yContour+Blocks(block).startPos(1)-1, xContour+Blocks(block).startPos(2)-1, zContour+Blocks(block).startPos(3)-1];
            tmpDot.Vox.Ind      = sub2ind([size(Post,1) size(Post,2) size(Post,3)], tmpDot.Vox.Pos(:,1), tmpDot.Vox.Pos(:,2), tmpDot.Vox.Pos(:,3));
            tmpDot.Vol          = numel(contourIndex);
            tmpDot.ITMax        = thresholdPeak;
            tmpDot.ItSum        = sum(Blocks(block).thresholdMap(contourIndex));
            tmpDot.Vox.RawBright= Blocks(block).Igm(contourIndex);
            tmpDot.Vox.IT       = Blocks(block).thresholdMap(contourIndex);
            tmpDot.MeanBright   = mean(Blocks(block).Igm(contourIndex));
            tmpDotNum           = tmpDotNum + 1; % Work on non-preallocated dots
            tmpDots(tmpDotNum)  = tmpDot;
        end
    end
end
fprintf(['DONE in ' num2str(toc) ' seconds \n']);

%% -- STEP 5: resolve empty dots and dots in border between blocks --
% Some voxels could be shared by multiple dots because of the overlapping
% search blocks approach in Step#1 and Step#2. Remove the smaller orbject.

% Convert tmpDots into the easily accessible fields 
fprintf('Resolving duplicate objects in the overlapping regions of search blocks... ');
tic;

Dots = struct;
iDots = 0;
for i = 1:numel(tmpDots)
    for j = 1 : i
        if tmpDots(i).Vol < tmpDots(j).Vol
            % ismembc is faster than ismember but requires ordered arrays
            if ismembc(tmpDots(i).Vox.Ind, tmpDots(j).Vox.Ind) 
                tmpDots(i).Vol = 0;
                break
            end
        end
    end
    
    if tmpDots(i).Vol == 0
        continue
    else
        iDots                       = iDots+1;
        Dots.Pos(iDots,:)           = tmpDots(i).Pos;
        Dots.Vox(iDots).Pos         = tmpDots(i).Vox.Pos;
        Dots.Vox(iDots).Ind         = tmpDots(i).Vox.Ind;
        Dots.Vol(iDots)             = tmpDots(i).Vol;
        Dots.ITMax(iDots)           = tmpDots(i).ITMax;
        Dots.ItSum(iDots)           = tmpDots(i).ItSum;
        Dots.Vox(iDots).RawBright   = tmpDots(i).Vox.RawBright;
        Dots.Vox(iDots).IT          = tmpDots(i).Vox.IT;
        Dots.MeanBright(iDots)      = tmpDots(i).MeanBright;
    end
end

Dots.ImSize = [size(Post,1) size(Post,2) size(Post,3)];
Dots.Num = numel(Dots.Vox); % Recalculate total number of dots
fprintf(['DONE in ' num2str(toc) ' seconds \n']);

clear B* CC contour* cutOff debug Gm* i j k Ig* labels Losing* ans
clear max* n* Num* Overlap* p peak* Possible* size(Post,2) size(Post,1) size(Post,3) Surrouding*
clear tmp* threshold* Total* T* v Vox* Winning* ws* x* y* z* DotsToDelete
clear block blockBuffer blockSize minDotSize minDotSize MultiPeakDotSizeCorrectionFactor
end