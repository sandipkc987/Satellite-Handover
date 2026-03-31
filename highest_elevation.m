%% HIGEST ELEVATION HANDOVER TABLE
% ========================================================================
% PURPOSE
% ========================================================================
% This script takes the raw visibility data from starlink_walker_constellation.m and turns it into
% something more useful for communication analysis - a clean handover
% sequence that tells you which satellite is actually serving Irving at
% any given moment, and when the link switches to a different satellite.
%
% The core idea is straightforward: at each time step, look at every
% satellite that Irving can see, pick the one with the highest elevation
% angle (higher elevation generally means a better link), and record it.
% A hysteresis guard is added so we don't thrash back and forth between
% two satellites that are nearly equal — a new satellite only takes over
% if it's meaningfully better than the current one and the current one
% has been serving for a reasonable amount of time.
%
% What this script produces:
%   handoverTimeline  — a row for every simulation sample showing which
%                       satellite is active at that exact moment
%   handoverTable     — a compressed version that merges consecutive rows
%                       with the same satellite into a single interval,
%                       making it easy to read the full handover sequence
%   Excel export      — two .xlsx files: one with the raw data sheets,
%                       one formatted for easy review
%   MAT-file export   — saves the key variables for use in later scripts
%
% ========================================================================

clc;
clear;
close all;

%% ========================================================================
% 1) LOAD WORKSPACE
% ========================================================================
% Everything we need — the satellite objects, TLE table, scenario timing,
% and sample rate was saved on starlink_walker_constellation.m file. Load it here so we don't have to
% rebuild the constellation from scratch.

saveFolder = 'C:\Users\sandy\Downloads\Handover';
matFileName = fullfile(saveFolder,'starlink_first_shell_workspace.mat');

load(matFileName);

fprintf('Workspace loaded successfully.\n');

%% ========================================================================
% 2) CREATE IRVING GROUND STATION
% ========================================================================
% Define Irving, Texas as the reference ground station. The 10-degree
% minimum elevation angle is a reasonable cut-off — satellites below that
% are generally too close to the horizon to give a reliable link.

gsLat        = 32.8140;
gsLon        = -96.9489;
gsAlt        = 0;
minElevation = 10;

irvingGS = groundStation(sc, ...
    "Name","Irving Texas", ...
    "Latitude",gsLat, ...
    "Longitude",gsLon, ...
    "Altitude",gsAlt, ...
    "MinElevationAngle",minElevation);

fprintf('Ground station created at Irving, Texas.\n');

%% ========================================================================
% 3) COMPUTE ACCESS STATUS FOR ALL SATELLITES
% ========================================================================
% Ask the satellite toolbox which satellites can see Irving at each time
% step. The result is a binary matrix — 1 means visible, 0 means not.
% We normalise it to [time x satellites] so the indexing is consistent
% throughout the rest of the script.

acMain = access(walkerSats, irvingGS);
[acStatsAllTime, timeHistory] = accessStatus(acMain);

numSats      = numel(walkerSats);
numTimeSteps = numel(timeHistory);

fprintf('Access status computed.\n');
fprintf('Satellites in constellation : %d\n', numSats);
fprintf('Time steps in scenario      : %d\n', numTimeSteps);

% The toolbox can return the matrix in either orientation depending on the
% version. Normalise to [time x satellites] regardless.
% Reason: At each time step → check all satellites
if size(acStatsAllTime,1) == numSats && size(acStatsAllTime,2) == numTimeSteps
    statusByTime = acStatsAllTime.';
elseif size(acStatsAllTime,1) == numTimeSteps && size(acStatsAllTime,2) == numSats
    statusByTime = acStatsAllTime;
else
    error('Unexpected access-status matrix size.');
end

%% ========================================================================
% 4) FIND THE HANDLER SATELLITE
% ========================================================================
% One satellite in the TLE table is flagged as the "handler" — a specific
% satellite of interest for this study. We locate its row index here so
% we can flag it in the output tables later.

handlerIndex = find(tleTable.IsHandler == true, 1, 'first');

if isempty(handlerIndex)
    error('Handler satellite not found in tleTable.');
end

fprintf('Handler index : %d\n', handlerIndex);
fprintf('Handler label : %s\n', tleTable.SatelliteLabel(handlerIndex));

%% ========================================================================
% 5) WORK OUT THE CORRECT ARGUMENT ORDER FOR aer()
% ========================================================================
% The aer() function (azimuth-elevation-range) changed its argument order
% between MATLAB releases. Rather than hardcoding one order and hoping for
% the best, we test it once here at startup and store the result. That way
% the main loop can call aer() correctly without any guesswork each step.

aerOrderGSFirst = true;   % default assumption: aer(groundStation, satellite, time)

try
    [~, ~, ~] = aer(irvingGS, walkerSats(1), timeHistory(1));
    aerOrderGSFirst = true;
    fprintf('aer() argument order confirmed: (groundStation, satellite, time)\n');
catch
    aerOrderGSFirst = false;
    fprintf('aer() argument order confirmed: (satellite, groundStation, time)\n');
end

%% ========================================================================
% 6) HYSTERESIS PARAMETERS
% ========================================================================
% Without a hysteresis guard, the selection algorithm would ping-pong
% between two nearly-equal satellites every 30 seconds or so whenever
% they happen to cross the same elevation angle. That's not realistic —
% in practice a real system would stay on the current satellite unless
% there's a genuine, sustained reason to switch.
%
% The two parameters below control this behaviour:
%   hysteresisMargin_deg  — a candidate satellite must beat the current
%                           serving satellite by at least this many degrees
%                           of elevation before a handover is triggered
%   minDwellSteps         — the current satellite must have been serving
%                           for at least this many time steps before we
%                           even consider switching away from it
%
% Setting both to zero reproduces the original greedy-max behaviour where
% every time step independently picks the highest-elevation satellite.

hysteresisMargin_deg = 6.0;   % degrees
minDwellSteps        = 10;    % time steps (~4 minutes at 30-second samples)

fprintf('\nHandover hysteresis margin : %.1f deg\n', hysteresisMargin_deg);
fprintf('Minimum dwell time         : %d steps (%d s)\n\n', ...
    minDwellSteps, minDwellSteps * sampleTime);

%% ========================================================================
% 7) PREPARE STORAGE ARRAYS
% ========================================================================
% Pre-allocate all output arrays up front. This matters because building
% a MATLAB table inside a loop by appending rows gets slower and slower as
% the table grows — each append copies the whole thing. Pre-allocating
% and filling in place is much faster and uses a predictable amount of memory.

bestSatIndex       = nan(numTimeSteps, 1);
bestElevation_deg  = nan(numTimeSteps, 1);
numVisibleSats     = zeros(numTimeSteps, 1);

% Hysteresis state variables — updated step by step through the loop
currentServingSat  = NaN;    % index of the satellite currently serving
dwellCount         = 0;      % how many consecutive steps we've been on it

% Timing and progress tracking
tStart = tic;
cumulativeSatelliteScans = 0;

fprintf('============================================================\n');
fprintf('Starting best-satellite selection...\n');
fprintf('============================================================\n');

%% ========================================================================
% 8) SELECT THE BEST SATELLITE AT EACH TIME STEP
% ========================================================================
% This is the main loop. For each time step we:
%   (a) find which satellites are visible
%   (b) compute their elevation angles in one vectorized call to aer()
%   (c) apply the hysteresis guard to decide whether to stay or switch
%   (d) record the serving satellite and its elevation
%
% The aer() call is vectorized across all visible satellites at once,
% so there is no inner loop over individual satellites. This makes the
% computation fast even with a large constellation.

for tIdx = 1:numTimeSteps

    currentTime  = timeHistory(tIdx);
    visibleIdx   = find(statusByTime(tIdx, :));
    numVisible   = numel(visibleIdx);
    numVisibleSats(tIdx) = numVisible;

    if numVisible == 0
        % Nobody in view — record a gap and reset the hysteresis state
        currentServingSat = NaN;
        dwellCount        = 0;
        bestSatIndex(tIdx)      = NaN;
        bestElevation_deg(tIdx) = NaN;

    else
        % Compute elevation angles for every visible satellite at once
        cumulativeSatelliteScans = cumulativeSatelliteScans + numVisible;

        if aerOrderGSFirst
            [~, elevAll, ~] = aer(irvingGS, walkerSats(visibleIdx), currentTime);
        else
            [~, elevAll, ~] = aer(walkerSats(visibleIdx), irvingGS, currentTime);
        end

        % Best candidate this step is simply the one with the highest elevation
        [bestEl, bestLocalIdx] = max(elevAll);
        candidateSatIdx = visibleIdx(bestLocalIdx);

        % ---- Hysteresis check ----
        % Is the current serving satellite still visible?
        currentStillVisible = ~isnan(currentServingSat) && ...
                               ismember(currentServingSat, visibleIdx);

        if ~currentStillVisible
            % The current satellite has dropped below the horizon — we have
            % no choice but to hand over to the best available candidate
            currentServingSat = candidateSatIdx;
            dwellCount        = 1;

        else
            % Current satellite is still visible. Check whether the candidate
            % is enough better to justify switching.
            currentLocalIdx  = find(visibleIdx == currentServingSat, 1);
            currentEl        = elevAll(currentLocalIdx);
            elevImprovement  = bestEl - currentEl;

            dwellCount = dwellCount + 1;

            if elevImprovement > hysteresisMargin_deg && dwellCount >= minDwellSteps
                % The improvement is large enough and we've been on this
                % satellite long enough — go ahead and hand over
                currentServingSat = candidateSatIdx;
                dwellCount        = 1;
            end
            % Otherwise: stay on the current satellite
        end

        bestSatIndex(tIdx) = currentServingSat;

        % Record the elevation of the satellite we're actually serving on,
        % not the candidate that triggered the check
        servingLocalIdx = find(visibleIdx == currentServingSat, 1);
        if ~isempty(servingLocalIdx)
            bestElevation_deg(tIdx) = elevAll(servingLocalIdx);
        else
            bestElevation_deg(tIdx) = bestEl;   % fallback — should not happen
        end
    end

    % Print progress every 10 steps so the console doesn't get flooded,
    % but always print the final step so we know it finished cleanly.
    if mod(tIdx, 10) == 0 || tIdx == numTimeSteps
        elapsedSec  = toc(tStart);
        pct         = 100 * tIdx / numTimeSteps;
        avgPerStep  = elapsedSec / tIdx;
        remainSec   = avgPerStep * (numTimeSteps - tIdx);

        if isnan(bestSatIndex(tIdx))
            bestLabel = "None";
        else
            bestLabel = tleTable.SatelliteLabel(bestSatIndex(tIdx));
        end

        fprintf(['Step %3d / %3d | %6.2f%% | Visible: %2d | ' ...
                 'Scans: %6d | Elapsed: %6.1f s | ' ...
                 'Remain: %6.1f s | Serving: %s\n'], ...
                 tIdx, numTimeSteps, pct, numVisible, ...
                 cumulativeSatelliteScans, elapsedSec, remainSec, bestLabel);
    end
end

%% ========================================================================
% 9) BUILD THE SAMPLE-BY-SAMPLE HANDOVER TIMELINE
% ========================================================================

validMask = ~isnan(bestSatIndex);

% Pre-allocate
ActiveSatellite  = repmat("No Satellite", numTimeSteps, 1);
PlaneNumber      = nan(numTimeSteps, 1);
SatelliteInPlane = nan(numTimeSteps, 1);
CatalogNumber    = nan(numTimeSteps, 1);
IsHandler        = false(numTimeSteps, 1);

if any(validMask)
    validIdxList = bestSatIndex(validMask);

    ActiveSatellite(validMask)  = tleTable.SatelliteLabel(validIdxList);
    PlaneNumber(validMask)      = tleTable.PlaneNumber(validIdxList);
    SatelliteInPlane(validMask) = tleTable.SatelliteInPlane(validIdxList);
    CatalogNumber(validMask)    = tleTable.CatalogNumber(validIdxList);
    IsHandler(validMask)        = tleTable.IsHandler(validIdxList);
end

bestElevation_deg = round(bestElevation_deg, 4);

HandoverFlag = false(numTimeSteps, 1);
for tIdx = 2:numTimeSteps
    if ~isequaln(bestSatIndex(tIdx), bestSatIndex(tIdx-1))
        HandoverFlag(tIdx) = true;
    end
end

handoverTimeline = table( ...
    timeHistory(:), ...
    bestSatIndex, ...
    ActiveSatellite, ...
    PlaneNumber, ...
    SatelliteInPlane, ...
    CatalogNumber, ...
    IsHandler, ...
    bestElevation_deg, ...
    numVisibleSats, ...
    HandoverFlag, ...
    'VariableNames', { ...
        'Time', ...
        'BestSatelliteIndex', ...
        'ActiveSatellite', ...
        'PlaneNumber', ...
        'SatelliteInPlane', ...
        'CatalogNumber', ...
        'IsHandler', ...
        'Elevation_deg', ...
        'NumVisibleSatellites', ...
        'HandoverFlag'} );

%% ========================================================================
% 10) MERGE CONSECUTIVE SELECTIONS INTO SERVING INTERVALS
% ========================================================================

maxSegments = numTimeSteps;

seg_HandoverNumber  = zeros(maxSegments, 1);
seg_ActiveSatellite = strings(maxSegments, 1);
seg_PlaneNumber     = nan(maxSegments, 1);
seg_SatInPlane      = nan(maxSegments, 1);
seg_CatalogNumber   = nan(maxSegments, 1);
seg_StartTime       = strings(maxSegments, 1);
seg_EndTime         = strings(maxSegments, 1);
seg_Duration_sec    = zeros(maxSegments, 1);
seg_MaxElevation    = nan(maxSegments, 1);
seg_MeanElevation   = nan(maxSegments, 1);

segCount     = 0;
segStart     = 1;
handoverNum  = 0;

for tIdx = 2:(numTimeSteps + 1)

    isBreak = (tIdx > numTimeSteps) || ...
              ~isequaln(bestSatIndex(tIdx), bestSatIndex(segStart));

    if isBreak
        handoverNum = handoverNum + 1;
        segEnd      = tIdx - 1;

        startTimeSeg = timeHistory(segStart);
        endTimeSeg   = timeHistory(segEnd) + seconds(sampleTime);
        durationSec  = round(seconds(endTimeSeg - startTimeSeg));
        selectedIdx  = bestSatIndex(segStart);

        segCount = segCount + 1;
        seg_HandoverNumber(segCount) = handoverNum;
        seg_StartTime(segCount)      = datestr(startTimeSeg, 'HH:MM:SS');
        seg_EndTime(segCount)        = datestr(endTimeSeg,   'HH:MM:SS');
        seg_Duration_sec(segCount)   = durationSec;

        if isnan(selectedIdx)
            seg_ActiveSatellite(segCount) = "No Satellite";

        else
            seg_ActiveSatellite(segCount) = tleTable.SatelliteLabel(selectedIdx);
            seg_PlaneNumber(segCount)     = tleTable.PlaneNumber(selectedIdx);
            seg_SatInPlane(segCount)      = tleTable.SatelliteInPlane(selectedIdx);
            seg_CatalogNumber(segCount)   = tleTable.CatalogNumber(selectedIdx);

            segElev = bestElevation_deg(segStart:segEnd);
            seg_MaxElevation(segCount)  = round(max(segElev,  [], 'omitnan'), 4);
            seg_MeanElevation(segCount) = round(mean(segElev, 'omitnan'),     4);
        end

        segStart = tIdx;
    end
end

handoverTable = table( ...
    seg_HandoverNumber(1:segCount), ...
    seg_ActiveSatellite(1:segCount), ...
    seg_PlaneNumber(1:segCount), ...
    seg_SatInPlane(1:segCount), ...
    seg_CatalogNumber(1:segCount), ...
    seg_StartTime(1:segCount), ...
    seg_EndTime(1:segCount), ...
    seg_Duration_sec(1:segCount), ...
    seg_MaxElevation(1:segCount), ...
    seg_MeanElevation(1:segCount), ...
    'VariableNames', { ...
        'HandoverNumber', ...
        'ActiveSatellite', ...
        'PlaneNumber', ...
        'SatelliteInPlane', ...
        'CatalogNumber', ...
        'StartTime', ...
        'EndTime', ...
        'Duration_sec', ...
        'MaxElevation_deg', ...
        'MeanElevation_deg'} );

%% ========================================================================
% 11) SUMMARY STATISTICS
% ========================================================================

validRows    = ~strcmp(handoverTable.ActiveSatellite, "No Satellite");
numHandovers = max(0, sum(validRows) - 1);

totalElapsed = toc(tStart);

fprintf('\n============================================================\n');
fprintf('BEST-SATELLITE SELECTION COMPLETE\n');
fprintf('============================================================\n');
fprintf('Satellites in constellation     : %d\n', numSats);
fprintf('Time steps processed            : %d\n', numTimeSteps);
fprintf('Cumulative satellite scans      : %d\n', cumulativeSatelliteScans);
fprintf('Merged serving intervals        : %d\n', height(handoverTable));
fprintf('Actual handovers                : %d\n', numHandovers);
fprintf('Hysteresis margin used          : %.1f deg\n', hysteresisMargin_deg);
fprintf('Min dwell time used             : %d steps\n', minDwellSteps);
fprintf('Runtime                         : %.2f seconds\n', totalElapsed);
fprintf('============================================================\n\n');

if ~isempty(handoverTable)
    disp('First 30 rows of handoverTable:');
    disp(handoverTable(1:min(30, height(handoverTable)), :));
end

%% ========================================================================
% 12) EXPORT RESULTS
% ========================================================================
% Two Excel files are produced:
%
%   highest_elevation.xlsx
%       Sheet 1 — HandoverTimeline : every time step with serving satellite
%       Sheet 2 — HandoverTable    : merged intervals, one row per service window
%
%   handover_reformatted.xlsx
%       A clean summary sheet built by grouping consecutive same-satellite
%       rows from the timeline into serving intervals.
%
%   highest_elevation_handover.mat
%       Saves the two tables and key parameters for use in downstream scripts.

excelRaw       = fullfile(saveFolder, 'highest_elevation.xlsx');
excelFormatted = fullfile(saveFolder, 'handover_reformatted.xlsx');
matOut         = fullfile(saveFolder, 'highest_elevation.mat');

% Raw data export
try
    writetable(handoverTimeline, excelRaw, 'Sheet', 'HandoverTimeline');
    writetable(handoverTable,    excelRaw, 'Sheet', 'HandoverTable');
    fprintf('Raw Excel saved:\n%s\n', excelRaw);
catch ME
    warning('Raw Excel export failed: %s', ME.message);
end

% Formatted report
try
    buildFormattedExcel(handoverTimeline, handoverTable, sampleTime, excelFormatted);
    fprintf('Formatted Excel saved:\n%s\n', excelFormatted);
catch ME
    warning('Formatted Excel failed: %s', ME.message);
end

% MAT-file
save(matOut, 'handoverTimeline', 'handoverTable', 'minElevation', ...
    'totalElapsed', 'cumulativeSatelliteScans', ...
    'hysteresisMargin_deg', 'minDwellSteps');
fprintf('MAT file saved:\n%s\n', matOut);

%% ========================================================================
% 13) NOTES FOR REFERENCE
% ========================================================================
% Selection logic
%   At each time step exactly one satellite is designated as serving.
%   The default criterion is highest elevation among visible satellites,
%   with the hysteresis guard preventing unnecessary handovers when two
%   satellites are close in elevation.
%
%   Set hysteresisMargin_deg = 0 and minDwellSteps = 0 to revert to the
%   simple greedy-max rule (always pick the highest satellite, no memory
%   of the previous step).
%
% Output tables
%   handoverTimeline  one row per simulation sample; use this if you need
%                     to analyse elevation trends or count visible satellites
%                     over time.
%   handoverTable     one row per serving interval; use this if you want to
%                     see the handover sequence, service durations, or
%                     elevation statistics.
%
% Formatted Excel report columns
%   #                 interval number in sequence
%   Active Satellite  name of the serving satellite
%   Plane / Sat-in-Plane / Catalog  constellation identifiers
%   Start / End Time  formatted as HH:MM:SS (time only)
%   Duration (sec)    total time this satellite was serving
%   Max Elevation     peak elevation during interval
%   Mean Elevation    average elevation during interval
%
% ========================================================================

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function orbitNum = estimateOrbitNumber(tleEpoch, t, n_rev_day, revAtEpoch)
    % Estimate the orbit number at time t by extrapolating from the TLE epoch.
    % This is a simple linear extrapolation — good enough for a 3-hour window.
    dt_days  = days(t - tleEpoch);
    orbitNum = floor(revAtEpoch + n_rev_day .* dt_days);
end

% -------------------------------------------------------------------------

function buildFormattedExcel(handoverTimeline, handoverTable, sampleTime, outFile)
% BUILDFORMATTEDEXCEL  Write a clean Excel handover report.
%
% Groups consecutive same-satellite rows from the timeline into serving
% intervals and writes a single summary sheet using writetable.
% Matches the simple export style used in the LVT script.
%
% Inputs:
%   handoverTimeline  — per-sample table from Section 9
%   handoverTable     — merged intervals table from Section 10
%   sampleTime        — scenario sample interval in seconds
%   outFile           — full output path for the .xlsx file

    nRows   = height(handoverTimeline);
    satIdx  = handoverTimeline.BestSatelliteIndex;
    timeVec = handoverTimeline.Time;
    elevVec = handoverTimeline.Elevation_deg;
    visVec  = handoverTimeline.NumVisibleSatellites;

    out_Num = {}; out_Active = {}; out_Plane = {}; out_SIP = {};
    out_Catalog = {}; out_Start = {}; out_End = {}; out_Duration = {};
    out_MaxElev = {}; out_MeanElev = {};

    i = 1; rowNum = 0;
    while i <= nRows
        j = i;
        while j <= nRows && isequaln(satIdx(j), satIdx(i)), j = j + 1; end
        segS = i; segE = j - 1; rowNum = rowNum + 1;

        startTime = timeVec(segS);
        endTime   = timeVec(segE) + seconds(sampleTime);
        durSec    = round(seconds(endTime - startTime));
        segElevs  = elevVec(segS:segE);

        out_Num{end+1,1}      = rowNum;
        out_Active{end+1,1}   = char(handoverTimeline.ActiveSatellite(segS));
        out_Plane{end+1,1}    = handoverTimeline.PlaneNumber(segS);
        out_SIP{end+1,1}      = handoverTimeline.SatelliteInPlane(segS);
        out_Catalog{end+1,1}  = handoverTimeline.CatalogNumber(segS);
        out_Start{end+1,1}    = datestr(startTime, 'HH:MM:SS');
        out_End{end+1,1}      = datestr(endTime,   'HH:MM:SS');
        out_Duration{end+1,1} = durSec;
        out_MaxElev{end+1,1}  = round(max(segElevs, [], 'omitnan'), 4);
        out_MeanElev{end+1,1} = round(mean(segElevs, 'omitnan'), 4);

        i = j;
    end

    reportTable = table( ...
        cell2mat(out_Num), out_Active, cell2mat(out_Plane), ...
        cell2mat(out_SIP), cell2mat(out_Catalog), out_Start, out_End, ...
        cell2mat(out_Duration), cell2mat(out_MaxElev), ...
        cell2mat(out_MeanElev), ...
        'VariableNames', { ...
            'HandoverNumber', 'ActiveSatellite', 'PlaneNumber', ...
            'SatelliteInPlane', 'CatalogNumber', 'StartTime', 'EndTime', ...
            'Duration_sec', 'MaxElevation_deg', 'MeanElevation_deg'});

    if exist(outFile, 'file'), delete(outFile); end
    writetable(reportTable, outFile, 'Sheet', 'Handover Summary');

end
