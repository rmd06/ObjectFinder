%% Object finder 
%
% *This program allows to analyze an image volume containing objects
% (i.e. labeling of synaptic structures) with the final goal of segmenting 
% each individual object and computing its indivudual properties.*
%
% The basic steps implemented by this semi-automate approach involve:
%
% * Load image stacks of the volume to inspect and supplemental labelings
%   (A mask is optionally provided to limit the search volume)
%
% <<LoadImages.png>>
%
% * Select options to restrict the search of candidate objects
%
% <<Preferences.png>>
%
%
% * Candidate objects are detected automatically using an iterative 
%   thresholding method followed by watershed segmentation. This process
%   is optimized for taking advantage of multi-core processors or
%   processing remote clusters by multi-threading operations.
%
% <<IterativeThreshold.png>>
%
% * The user is requested to filter candidate objects according to one 
%   or more parameters, by setting a threshold (usually using ITmax)
% * The user refine the selection by 3D visual inspection using Imaris
%
% <<PunctaIdentification.png>>
%
% * Object distribution and density is calculated in the volume or across
%   the cell skeleton.
% * If no skeleton is present, object density is plotted against Z depth
%
% The main search loop follows the logic described in:
%
%  Developmental patterning of glutamatergic synapses onto 
%  retinal ganglion cells.
%  Morgan JL, Schubert T, Wong RO. Neural Dev. (2008) 26;3:8.
%
% Originally written for the detection of postsynaptic PSD95 puncta on
% dendrites of gene-gun labelled retinal ganglion cells
%
% *Dependencies:*  
%
% * Imaris 7.2.3
% * Image Processing Toolbox
% * Parallel Computing Toolbox
%

% Preliminary check of valid current working directory structure
if ~isdir([pwd filesep 'I'])
    error(['This folder is not valid for ObjectFinder analysis, '...
           'please change current working directory to one containing '...
           'images to analyze within an "I" subfolder']); 
end

% Get the current working folder as base directory for the analysis
disp('---- ObjectFinder 3.0 analysis ----');
Settings.TPN = [pwd filesep]; 
if exist([Settings.TPN 'Settings.mat'], 'file')
    load([Settings.TPN 'Settings.mat']);
else
    save([Settings.TPN 'Settings.mat'], 'Settings');
end
if ~isdir([Settings.TPN 'data']), mkdir([Settings.TPN 'data']); end
if ~isdir([Settings.TPN 'find']), mkdir([Settings.TPN 'find']); end

% Read images to be used for analysis
tmpDir=[Settings.TPN 'I' filesep];
tmpFiles=dir([tmpDir '*.tif']);

% Get dimensions of the first image (assumes each channel stored as individual 3D .tif file coming from same acquisition)
tmpImInfo = imfinfo([tmpDir tmpFiles(1).name]);
zs = numel(tmpImInfo);
xs = tmpImInfo.Width;
ys = tmpImInfo.Height;

% Retrieve XY and Z resolution from TIFF image descriptor
tmpXYres = num2str(1/tmpImInfo(1).XResolution);
if contains(tmpImInfo(1).ImageDescription, 'spacing=')
    tmpPos = strfind(tmpImInfo(1).ImageDescription,'spacing=');
    tmpZres = tmpImInfo(1).ImageDescription(tmpPos+8:end);
    tmpZres = regexp(tmpZres,'\n','split');
    tmpZres = tmpZres{1};
else
    tmpZres = '0.3'; % otherwise use default value
end

% Read all .tif images into a single Iraw matrix (X,Y,Z,Imge#)
Iraw=zeros(ys, xs, zs, numel(tmpFiles), 'uint8');
txtBar('Loading image stacks... ');
for i = 1:numel(tmpFiles)
    for j = 1:zs
        Iraw(:,:,j,i)=imread([tmpDir tmpFiles(i).name], j);
        txtBar( 100*(j+i*zs-zs)/(zs*numel(tmpFiles)) );
    end
end
txtBar('DONE');

Imax=squeeze(max(Iraw,[],3)); % Create a MIP of each image
cfigure(size(Imax,3)*10, 8);  % Size panel to # of images to display
for i = 1:size(Imax,3)    
    subplot(1,size(Imax,3),i)
    image(Imax(:,:,i)*(500/double(max(max(Imax(:,:,i))))))
    title(['# ' num2str(i) ': ' tmpFiles(i).name]);
    set(gca,'box','off');
    set(gca,'YTickLabel',[],'XTickLabel',[]);
end
colormap gray(256);

% Ask user for image idendity settings
tmpPrompt = {'Objects image #:',...
             'Mask channel (0:no/use Mask.mat):',...
             'Neurites image # (0 = none):',...
             'xy resolution :',...
             'z resolution :',...
             'Debug mode (0:no, 1:yes):'};
tmpAns = inputdlg(tmpPrompt, 'Assign channels', 1,...
            {'3', '0', '1',tmpXYres,tmpZres,'0'});

Settings.ImInfo.xNumVox = xs;
Settings.ImInfo.yNumVox = ys;
Settings.ImInfo.zNumVox = zs;
Settings.ImInfo.PostCh  = str2double(tmpAns(1));
Settings.ImInfo.MaskCh  = str2double(tmpAns(2));
Settings.ImInfo.DenCh   = str2double(tmpAns(3));
Settings.ImInfo.xyum    = str2double(tmpAns(4));
Settings.ImInfo.zum     = str2double(tmpAns(5));
Settings.debug          = str2double(tmpAns(6));
save([Settings.TPN 'Settings.mat'], 'Settings');

% Write Channels into matlab files
if Settings.ImInfo.DenCh
    Dend = Iraw(:,:,:,Settings.ImInfo.DenCh);
    save([Settings.TPN 'Dend.mat'],'Dend');
end

if Settings.ImInfo.PostCh
    Post=Iraw(:,:,:,Settings.ImInfo.PostCh);
    save([Settings.TPN 'Post.mat'],'Post');
end

if Settings.ImInfo.MaskCh
    Mask = Iraw(:,:,:,Settings.ImInfo.MaskCh);
    Mask = Mask / max(max(max(Mask))); % Normalize mask max value to 1
    save([Settings.TPN 'Mask.mat'],'Mask');
    if isdir([Settings.TPN 'find'])==0, mkdir([Settings.TPN 'find']); end % Create directory to store steps
    saveastiff(Post, [Settings.TPN 'find' filesep 'PostMask.tif']); %save 3-D tiff image of the masked Post
elseif exist([Settings.TPN 'Mask.mat'], 'file')
    disp('Loading Mask from Mask.mat');
    load([Settings.TPN 'Mask.mat']);
else
    % Create dummy mask with all ones to process the entire image
    Mask = ones(size(Post), 'uint8');
    save([Settings.TPN 'Mask.mat'],'Mask');
end
close all; clear i j Iraw Imax Is tmp* xs ys zs ans;

tmpPrompt = {'x-y diameter of the biggest dot (um, default 1)',...
             'z diameter of the biggest dot (um, default 2)',...
             'x-y diameter of the smallest dot (um, default 0.25)',...
             'z diameter of the smallest dot (um, normally 0.5)',...
             'Intensity thresholds stepping (default 2)',...
             'Multi-peak correction factor (default 0)',...
             'Minimum iteration threshold (default 2)'};
tmpAns = inputdlg(tmpPrompt, 'ObjectFinder settings', 1,...
           {'1','2','0.25','0.5','2','0','2'});

% Calculate volume of the minimum / maximum dot sizes allowed
% largest CtBP2 = elipsoid 1um-xy/2um-z diameter = ~330 voxels (.103x.103x0.3 um pixel size)
MaxDotSize = (4/3*pi*(str2double(tmpAns(1))/2)*(str2double(tmpAns(1))/2)*(str2double(tmpAns(2))/2)) / (Settings.ImInfo.xyum*Settings.ImInfo.xyum*Settings.ImInfo.zum);
MinDotSize = (4/3*pi*(str2double(tmpAns(3))/2)*(str2double(tmpAns(3))/2)*(str2double(tmpAns(4))/2)) / (Settings.ImInfo.xyum*Settings.ImInfo.xyum*Settings.ImInfo.zum);

Settings.dotfinder.blockBuffer= round(str2double(tmpAns(1))/Settings.ImInfo.xyum);  % Overlapping buffer region between search block should be as big as the biggest dot we want to measure to make sure we are not missing any.
%Settings.dotfinder.blockSize = 3* Settings.dotfinder.blockBuffer; % Use 3x blockBuffer for maximum speed during multi-threaded operations (best setting for speed)
Settings.dotfinder.blockSize = 64; % Fixed this value to 64 otherwise computers with 16Gb RAM will run easily out of memory
Settings.dotfinder.thresholdStep = str2double(tmpAns(5)); % step-size in the iterative search when looping through possible intensity values
Settings.dotfinder.maxDotSize = MaxDotSize;       % max dot size exclusion criteria for single-peak dot DURING ITERATIVE THRESHOLDING, NOT FINAL.
Settings.dotfinder.minDotSize= 3;                 % min dot size exclusion criteria DURING ITERATIVE THRESHOLDING, NOT FINAL.
Settings.dotfinder.MultiPeakDotSizeCorrectionFactor = str2double(tmpAns(6)); % added by HO 2/8/2011, maxDotSize*MultiPeakDotSizeCorrectionFactor will be added for each additional dot joined to the previous dot, see dotfinder. With my PSD95CFP dots, super multipeak dots are rare, so put 0 for this factor.
Settings.dotfinder.itMin = str2double(tmpAns(7)); % added by HO 2/9/2011 minimum iterative threshold allowed to be analyzed as voxels belonging to any dot...filter to remove value '1' pass thresholds. value '2' is also mostly noise for PSD95 dots, so 3 is the good starting point HO 2/9/2011
Settings.dotfinder.peakCutoffLowerBound = 0.2;    % set threshold for all dots (0.2) after psychophysical testing with linescan and full 8-bit depth normalization HO 6/4/2010
Settings.dotfinder.peakCutoffUpperBound = 0.2;    % set threshold for all dots (0.2) after psychophysical testing with linescan and full 8-bit depth normalization HO 6/4/2010
Settings.dotfinder.minFinalDotITMax = 3;          % minimum ITMax allowed as FINAL dots. Any found dot whose ITMax is below this threshold value is removed from the registration into Dots. 5 will be the best for PSD95. HO 1/5/2010
Settings.dotfinder.minFinalDotSize = MinDotSize;  % Minimum dot size allowed for FINAL dots.

save([Settings.TPN 'Settings.mat'], 'Settings');
clear BlockBuffer MaxDotSize MinDotSize tmp*

% --- Find objects and calculate their properties ---
% Seach objects inside the masked volume
[Dots, Settings] = findObjects(Post.*Mask, Settings);
save([Settings.TPN 'Dots.mat'],'Dots');
save([Settings.TPN 'Settings.mat'],'Settings');

% Create fields about sphericity of dots (Rounding)
Dots = fitSphere(Dots, Settings.debug); 
save([Settings.TPN 'Dots.mat'],'Dots');

% Filter objects according to the following post-processing criteria (SG)
SGOptions.EdgeDotCut = 1;    % remove dots on edge of the expanded mask
SGOptions.SingleZDotCut = 1; % remove dots sitting on only one Z plane
SGOptions.xyStableDots = 0;
SGOptions.PCA = 0;
SGOptions.MinThreshold = 0;
SG = filterObjects(Settings, SGOptions);

% In Imaris select ItMax as filter, and export objects back to matlab.
exportObjectsToImaris(Settings, Dots, SG); % Transfer objects to Imaris
SG = filterObjects(Settings);              % Synch objects exported from Imaris

% Group dots that are facing each other and recalculate properties
load([Settings.TPN 'Settings.mat']);
Grouped = groupFacingObjects(Dots, SG, Settings);
Grouped = fitSphere(Grouped, Settings.debug); 
save([Settings.TPN 'Grouped.mat'],'Grouped');

% If a skeleton is present then calculate properties of the individual cell
if exist([Settings.TPN 'Skel.mat'], 'file')
    load([Settings.TPN 'Skel.mat'])
    load([Settings.TPN 'Settings.mat'])
    Skel = calcSkelPathLength(Skel, Settings.debug);
    save([Settings.TPN 'Skel.mat'],'Skel')
    Skel = generateFinerSkel(Skel, Settings.ImInfo.xyum, Settings.debug);
    Skel = calcSkelPathLength(Skel, Settings.debug);
    save([Settings.TPN 'SkelFiner.mat'], 'Skel');
    Grouped = distDotsToCellBody(Grouped, Skel, Settings);
    Grouped = distDotsToSkel(Grouped, Skel, Settings);
    save([Settings.TPN 'Grouped.mat'],'Grouped');

    % Generate Use.mat and calculate dendrite distribution
    % TODO: Figure out what this function accumulates because used by all following
    close all;
    anaMakeUseOnec(Grouped, Skel, Settings);
    disp('Click on the maximum in the first plot (red) and hit return');
    anaDotsDD(Settings);
    close all;
    anaCAsampleUse(Settings); % Generate heatmaps (CA) of puncta/skeleton
    calcPathLengthStats(Settings.TPN, Grouped, Skel); % Plot distribution along dendrites
else
    % Compute and plot object distribution as function of volume depth
    dotDensity = calcDotDensityAlongZ(Grouped);
    save([Settings.TPN 'dotDensity'], 'dotDensity') %fixed to save only Settings (9/2/09 HO)
end

disp('---- ObjectFinder analysis done! ----');
%% Change log
% _*Version 3.0*               created on 2017-11-03 by Luca Della Santina_
%
%  + Multi-threaded findObjects (times faster = number of cores available)
%  + Complete multi-platform support (Windows / macOS / Linux)
%  + Z resolution is automatically detected from TIFF image description
%  - Removed median filtering of source images (unuseful to most people)
%  - Removed experiment detail description (unuseful to most people)
%  % All settings are stored in Settings.mat (no more TPN and similar file)
%  % Throw error if current working directory strucrue is invalid
%
% _*Version 2.5*               created on 2017-10-22 by Luca Della Santina_
%
%  + Display more than 4 images if present in the I folder
%  + Automatically read x-y image resolution from tif files saved by ImageJ
%  + Added text progress bars to follow progress during processing steps
%  + Added debug=0/1 mode in subroutines to toggle text/graphic output
%  - Removed dependency from getVars() to get user input
%  - Removed redundances in user inputs (i.e. image resolution asked twice)
%  - Removed anaRa, anaRead, CAsampleCollect, StratNoCBmedian, Gradient
%  - Merged redundant scripts(anaCB/anaCBGrouped, anaRd/anaRdGrouped)
%  % Unified Imaris XTensions under ObjectFinder_ names
%  % Imaris extensions provided visual confirmation dialog upon success
%  % Restructured main look into 4 distinct operations for maintainability
%  % Return Dots from objFinder and others instead of saving on disk
%  % Replaced GetMyDir dependency with pwd and work from current folder
%  % filterObjects(TPN) skips questions and just reprocess Imaris dots
%  % Stored ImageInfo (size,res) inside Grouped.InInfo for plotting
%
% _*Version 2.0*   created on 2010-2011 by Hauhisa Okawa and Adam Bleckert_
%
%  % Improved speed of dot searching by resrtricting search within mask
%  % Improved speed of dot searching by working on Uint8 values
%  + Partial comments added to the original routines
%  + Puncta linear density, distances now calculated along dendritic path
%
% _*Version 1.0*                            created on 2008 by Josh Morgan_
%
% _*TODO*_
%
%  Resolve minDotsize vs minFnalDotSize (current minDotSize fixed at 3px)
%  Implement stepping=1 through gmode instead (current stepping of 2)
%  Check LDSCAsampleCollect and LDSCAsampleUse calculate density differently
%  When searching one signal (i.e. ctbp2 in IPL stack) prompt user several 
%  sample fields to choose an appropriate ITmax threshold
%  findObjects() Post is broadcasted to every worker, slice Igm better 
%  grupFacingObjects, move this before imaris step to limit number of click