%% LONGEST VISUAL TIME — REALISTIC CAUSAL (FAST / VECTORISED)
% ========================================================================
% PURPOSE
% ========================================================================
% Causal LVT strategy with vectorised aer() and a WARNING-ZONE HANDOVER
% MARGIN plus a DWELL GRACE PERIOD to prevent ping-pong switching.
%
%  The terminal stays on the current satellite until one of two things:
%    (a) It drops below the hard floor (10 deg) — FORCED handover
%    (b) It drops below the soft margin (18 deg) AND the terminal has
%        been on it for at least minDwellSteps — PROACTIVE handover
%
%  The dwell grace period is critical. Without it, the algorithm picks a
%  new satellite that may start at 12-13 deg (just rising), which is
%  already below the 18 deg margin, causing an immediate re-trigger.
%  This chain reaction creates 4-6 rapid 30-second handovers before a
%  satellite finally rises above the margin. The grace period prevents
%  this by giving a newly-selected satellite time to rise before the
%  margin check applies.
%
%  Parameters:
%    minElevation       = 10 deg   (hard floor — invisible below this)
%    handoverMargin_deg = 18 deg   (soft warning — start scanning)
%    minDwellSteps      = 4        (grace period after handover)
%
% ========================================================================

clc;
clear;
close all;

%% ========================================================================
% 1) LOAD WORKSPACE
% ========================================================================

saveFolder  = 'C:\Users\sandy\Downloads\Handover';
matFileName = fullfile(saveFolder, 'starlink_first_shell_workspace.mat');

load(matFileName);
fprintf('Workspace loaded.\n');

%% ========================================================================
% 2) GROUND STATION
% ========================================================================

gsLat        = 32.8140;
gsLon        = -96.9489;
gsAlt        = 0;
minElevation = 10;

irvingGS = groundStation(sc, ...
    'Name',              'Irving Texas', ...
    'Latitude',          gsLat, ...
    'Longitude',         gsLon, ...
    'Altitude',          gsAlt, ...
    'MinElevationAngle', minElevation);

fprintf('Ground station created at Irving, Texas.\n');

%% ========================================================================
% 3) BUILD TIME VECTOR
% ========================================================================

scenarioStart = sc.StartTime;
scenarioStop  = sc.StopTime;

timeHistory  = scenarioStart : seconds(sampleTime) : scenarioStop;
timeHistory  = timeHistory(:);

numSats      = numel(walkerSats);
numTimeSteps = numel(timeHistory);

fprintf('Time vector built.\n');
fprintf('Satellites : %d\n', numSats);
fprintf('Time steps : %d\n', numTimeSteps);

%% ========================================================================
% 4) HANDLER SATELLITE
% ========================================================================

handlerIndex = find(tleTable.IsHandler == true, 1, 'first');

if isempty(handlerIndex)
    error('Handler satellite not found in tleTable.');
end

fprintf('Handler index : %d\n', handlerIndex);
fprintf('Handler label : %s\n', tleTable.SatelliteLabel(handlerIndex));

%% ========================================================================
% 5) DETECT aer() ARGUMENT ORDER
% ========================================================================

aerOrderGSFirst = true;

try
    [~, ~, ~] = aer(irvingGS, walkerSats(1), timeHistory(1));
    aerOrderGSFirst = true;
    fprintf('aer() order : (groundStation, satellite, time)\n');
catch
    aerOrderGSFirst = false;
    fprintf('aer() order : (satellite, groundStation, time)\n');
end

%% ========================================================================
% 6) HANDOVER MARGIN + DWELL PARAMETERS
% ========================================================================
% handoverMargin_deg : soft threshold — when the serving satellite drops
%                      below this, we start looking for a replacement
% minDwellSteps      : grace period — a newly-selected satellite must be
%                      served for at least this many steps before the
%                      margin check applies to it. This prevents the
%                      ping-pong problem where the algorithm picks a
%                      rising satellite at 12 deg, immediately re-triggers
%                      the margin (12 < 18), picks another, re-triggers
%                      again, etc.
%
% With minDwellSteps = 4 at 30-sec samples, the grace period is 2 minutes.
% A typical LEO satellite rises from 10 to 18+ deg in about 1-2 minutes,
% so 4 steps is enough for it to climb above the margin.

handoverMargin_deg = 18;    % degrees
minDwellSteps      = 4;     % steps (~2 min at 30-sec samples)

fprintf('\nHandover margin parameters:\n');
fprintf('  Hard minimum (invisible)   : %d deg\n', minElevation);
fprintf('  Soft warning (start scan)  : %d deg\n', handoverMargin_deg);
fprintf('  Preparation window         : %d deg\n', handoverMargin_deg - minElevation);
fprintf('  Dwell grace period         : %d steps (%d s)\n', ...
    minDwellSteps, minDwellSteps * sampleTime);

%% ========================================================================
% 7) PRE-ALLOCATE OUTPUT ARRAYS
% ========================================================================

bestSatIndex         = nan(numTimeSteps, 1);
bestElevation_deg    = nan(numTimeSteps, 1);
bestRemainingVis_sec = nan(numTimeSteps, 1);
numVisibleSats       = zeros(numTimeSteps, 1);
handoverMarginLog    = nan(numTimeSteps, 1);

currentServingSat        = NaN;
dwellCount               = 0;
cumulativeSatelliteScans = 0;
tStart                   = tic;

fprintf('\n============================================================\n');
fprintf('Starting FAST Realistic LVT selection (margin + dwell guard)...\n');
fprintf('============================================================\n\n');

%% ========================================================================
% 8) MAIN SELECTION LOOP
% ========================================================================
%
% At each step:
%
%   Case 1 — serving satellite is above the soft margin, OR we haven't
%            served it long enough (dwellCount < minDwellSteps)
%            -> stay connected
%
%   Case 2 — serving satellite is below soft margin AND dwellCount >= minDwellSteps
%            -> PROACTIVE handover (margin triggered)
%
%   Case 3 — serving satellite below hard floor or first step
%            -> FORCED handover (no grace period needed)

for tIdx = 1:numTimeSteps

    currentTime = timeHistory(tIdx);

    % ── Single vectorised aer() call for ALL satellites ───────────────────
    if aerOrderGSFirst
        [~, elevAll, ~] = aer(irvingGS, walkerSats, currentTime);
    else
        [~, elevAll, ~] = aer(walkerSats, irvingGS, currentTime);
    end

    visibleIdx = find(elevAll >= minElevation);
    numVisible = numel(visibleIdx);
    numVisibleSats(tIdx) = numVisible;

    if numVisible == 0
        % ── Coverage gap ─────────────────────────────────────────────────
        currentServingSat          = NaN;
        dwellCount                 = 0;
        bestSatIndex(tIdx)         = NaN;
        bestElevation_deg(tIdx)    = NaN;
        bestRemainingVis_sec(tIdx) = 0;

    else
        cumulativeSatelliteScans = cumulativeSatelliteScans + numVisible;

        % Is the current serving satellite still above the HARD floor?
        currentStillVisible = ~isnan(currentServingSat) && ...
                               ismember(currentServingSat, visibleIdx);

        if currentStillVisible
            currentElev = elevAll(currentServingSat);
        end

        % Decide which case
        needsHandover = false;
        handoverType  = "";

        if ~currentStillVisible
            needsHandover = true;
            handoverType  = "FORCED";

        elseif currentElev < handoverMargin_deg && dwellCount >= minDwellSteps
            needsHandover = true;
            handoverType  = "MARGIN";
        end

        if ~needsHandover
            % ── Case 1: stay on current satellite ─────────────────────────
            dwellCount = dwellCount + 1;

            bestSatIndex(tIdx)      = currentServingSat;
            bestElevation_deg(tIdx) = round(elevAll(currentServingSat), 4);

            remVec = predictRemainingVisFast( ...
                irvingGS, walkerSats(currentServingSat), ...
                currentTime, sampleTime, minElevation, aerOrderGSFirst);
            bestRemainingVis_sec(tIdx) = remVec;

        else
            % ── Case 2 or 3: handover ────────────────────────────────────
            if strcmp(handoverType, "MARGIN")
                triggerElev = currentElev;
            elseif currentStillVisible
                triggerElev = currentElev;
            else
                triggerElev = NaN;
            end

            fprintf('  [t=%3d  %s] %s handover (dwell=%d) — scanning %d candidates...', ...
                    tIdx, datestr(currentTime,'HH:MM:SS'), handoverType, dwellCount, numVisible);

            if ~isnan(triggerElev)
                fprintf(' (serving elev: %.1f deg)\n', triggerElev);
            else
                fprintf('\n');
            end

            tHO = tic;

            visRemaining = predictRemainingVisFast( ...
                irvingGS, walkerSats(visibleIdx), ...
                currentTime, sampleTime, minElevation, aerOrderGSFirst);

            elevVisible = elevAll(visibleIdx);

            % Exclude current satellite if margin-triggered
            if strcmp(handoverType, "MARGIN") && numel(visibleIdx) > 1
                excludeMask        = (visibleIdx == currentServingSat);
                candidateIdx       = visibleIdx(~excludeMask);
                candidateRemaining = visRemaining(~excludeMask);
                candidateElev      = elevVisible(~excludeMask);
            else
                candidateIdx       = visibleIdx;
                candidateRemaining = visRemaining;
                candidateElev      = elevVisible;
            end

            maxRemaining = max(candidateRemaining);
            tiedMask     = (candidateRemaining == maxRemaining);
            tiedLocalIdx = find(tiedMask);

            if numel(tiedLocalIdx) == 1
                bestLocalIdx = tiedLocalIdx;
            else
                [~, tieBreaker] = max(candidateElev(tiedLocalIdx));
                bestLocalIdx    = tiedLocalIdx(tieBreaker);
            end

            currentServingSat = candidateIdx(bestLocalIdx);
            dwellCount        = 1;    % reset for new satellite

            bestSatIndex(tIdx)         = currentServingSat;
            bestElevation_deg(tIdx)    = round(candidateElev(bestLocalIdx), 4);
            bestRemainingVis_sec(tIdx) = maxRemaining;
            handoverMarginLog(tIdx)    = triggerElev;

            fprintf('  [t=%3d] Selected: %s | Window: %.0f s | Scan: %.2f s\n', ...
                    tIdx, tleTable.SatelliteLabel(currentServingSat), ...
                    maxRemaining, toc(tHO));
        end
    end

    % Progress every 10 steps
    if mod(tIdx, 10) == 0 || tIdx == numTimeSteps
        elapsed = toc(tStart);
        pct     = 100 * tIdx / numTimeSteps;
        remEst  = (elapsed / tIdx) * (numTimeSteps - tIdx);

        if isnan(bestSatIndex(tIdx))
            lbl = "None"; remLbl = 0;
        else
            lbl = tleTable.SatelliteLabel(bestSatIndex(tIdx));
            remLbl = bestRemainingVis_sec(tIdx);
        end

        fprintf(['Step %3d/%3d | %5.1f%% | Vis: %2d | ' ...
                 'Elapsed: %5.1f s | Rem est: %5.1f s | ' ...
                 'Serving: %s | RemVis: %.0f s\n'], ...
                 tIdx, numTimeSteps, pct, numVisible, ...
                 elapsed, remEst, lbl, remLbl);
    end
end

%% ========================================================================
% 9) BUILD HANDOVER TIMELINE
% ========================================================================

validMask = ~isnan(bestSatIndex);

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

bestRemainingVis_sec = round(bestRemainingVis_sec);

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
    bestRemainingVis_sec, ...
    numVisibleSats, ...
    HandoverFlag, ...
    handoverMarginLog, ...
    'VariableNames', { ...
        'Time', ...
        'BestSatelliteIndex', ...
        'ActiveSatellite', ...
        'PlaneNumber', ...
        'SatelliteInPlane', ...
        'CatalogNumber', ...
        'IsHandler', ...
        'Elevation_deg', ...
        'PredictedRemainingVisibility_sec', ...
        'NumVisibleSatellites', ...
        'HandoverFlag', ...
        'HandoverMargin_deg'} );

%% ========================================================================
% 10) MERGE INTO SERVING INTERVALS
% ========================================================================
% HandoverTable columns match the HEA script format:
%   HandoverNumber, ActiveSatellite, PlaneNumber, SatelliteInPlane,
%   CatalogNumber, StartTime, EndTime, Duration_sec,
%   MaxElevation_deg, MeanElevation_deg, HandoverMargin_deg

maxSegments         = numTimeSteps;
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
seg_HandoverMargin  = nan(maxSegments, 1);

segCount    = 0;
segStart    = 1;
handoverNum = 0;

for tIdx = 2:(numTimeSteps + 1)

    isBreak = (tIdx > numTimeSteps) || ...
              ~isequaln(bestSatIndex(tIdx), bestSatIndex(segStart));

    if isBreak
        handoverNum  = handoverNum + 1;
        segEnd       = tIdx - 1;
        startTimeSeg = timeHistory(segStart);
        endTimeSeg   = timeHistory(segEnd) + seconds(sampleTime);
        durationSec  = round(seconds(endTimeSeg - startTimeSeg));
        selectedIdx  = bestSatIndex(segStart);

        segCount = segCount + 1;
        seg_HandoverNumber(segCount) = handoverNum;
        seg_StartTime(segCount)      = datestr(startTimeSeg, 'HH:MM:SS');
        seg_EndTime(segCount)        = datestr(endTimeSeg,   'HH:MM:SS');
        seg_Duration_sec(segCount)   = durationSec;
        seg_HandoverMargin(segCount) = handoverMarginLog(segStart);

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
    seg_HandoverMargin(1:segCount), ...
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
        'MeanElevation_deg', ...
        'HandoverMargin_deg'} );

%% ========================================================================
% 11) SUMMARY
% ========================================================================

validRows    = ~strcmp(handoverTable.ActiveSatellite, 'No Satellite');
numHandovers = max(0, sum(validRows) - 1);
totalElapsed = toc(tStart);

marginHandovers = sum(~isnan(seg_HandoverMargin(1:segCount)) & ...
                      seg_HandoverMargin(1:segCount) >= minElevation);
forcedHandovers = numHandovers - marginHandovers;

fprintf('\n============================================================\n');
fprintf('FAST REALISTIC LVT — COMPLETE (margin + dwell guard)\n');
fprintf('============================================================\n');
fprintf('Mode              : Causal — no future data used\n');
fprintf('Hard minimum      : %d deg\n', minElevation);
fprintf('Soft margin       : %d deg\n', handoverMargin_deg);
fprintf('Dwell grace       : %d steps (%d s)\n', minDwellSteps, minDwellSteps * sampleTime);
fprintf('Satellites        : %d\n', numSats);
fprintf('Time steps        : %d\n', numTimeSteps);
fprintf('Satellite scans   : %d\n', cumulativeSatelliteScans);
fprintf('Serving intervals : %d\n', height(handoverTable));
fprintf('Total handovers   : %d\n', numHandovers);
fprintf('  Proactive (margin) : %d\n', marginHandovers);
fprintf('  Forced (sat set)   : %d\n', forcedHandovers);
fprintf('Runtime           : %.2f s\n', totalElapsed);
fprintf('============================================================\n\n');

if ~isempty(handoverTable)
    disp('First 30 rows of handoverTable:');
    disp(handoverTable(1:min(30,height(handoverTable)), :));
end

%% ========================================================================
% 12) EXPORT
% ========================================================================

excelRaw       = fullfile(saveFolder, 'lvt_realworld_fast_handover.xlsx');
excelFormatted = fullfile(saveFolder, 'lvt_realworld_fast_handover_formatted.xlsx');
matOut         = fullfile(saveFolder, 'lvt_realworld_fast_handover.mat');

try
    writetable(handoverTimeline, excelRaw, 'Sheet', 'HandoverTimeline');
    writetable(handoverTable,    excelRaw, 'Sheet', 'HandoverTable');
    fprintf('Excel saved: %s\n', excelRaw);
catch ME
    warning('Excel export failed: %s', ME.message);
end

try
    buildFormattedExcel(handoverTimeline, handoverTable, sampleTime, ...
                        handoverMargin_deg, minElevation, excelFormatted);
    fprintf('Formatted Excel saved:\n%s\n', excelFormatted);
catch ME
    warning('Formatted Excel failed: %s', ME.message);
end

save(matOut, 'handoverTimeline', 'handoverTable', ...
     'minElevation', 'handoverMargin_deg', 'minDwellSteps', ...
     'totalElapsed', 'cumulativeSatelliteScans');
fprintf('MAT saved:   %s\n', matOut);

%% ========================================================================
% 13) NOTES FOR REFERENCE
% ========================================================================
% Handover margin + dwell logic
%   A handover scan triggers when BOTH conditions are met:
%     1. Elevation < handoverMargin_deg (18 deg)
%     2. dwellCount >= minDwellSteps (4 steps = 2 minutes)
%
%   The dwell grace period prevents ping-pong: without it, a rising
%   satellite at 12 deg immediately re-triggers the margin (12 < 18),
%   causing a chain of 4-6 rapid handovers every 30 seconds.
%
%   If the satellite drops below the hard floor (10 deg), a forced
%   handover occurs regardless of dwell count.
%
% HandoverTable columns:
%   HandoverNumber     sequential interval number
%   ActiveSatellite    serving satellite name
%   PlaneNumber        orbital plane
%   SatelliteInPlane   position in plane
%   CatalogNumber      NORAD catalog number
%   StartTime          HH:MM:SS
%   EndTime            HH:MM:SS
%   Duration_sec       serving time in seconds
%   MaxElevation_deg   peak elevation during interval
%   MeanElevation_deg  average elevation during interval
%   HandoverMargin_deg elevation of PREVIOUS satellite at trigger
%                      (NaN for first interval or coverage gaps)
%
% ========================================================================

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function remSec = predictRemainingVisFast(gs, sats, tNow, stepSec, minEl, gsFirst)
    nSats           = numel(sats);
    maxLookaheadSec = 3600;
    maxSteps        = floor(maxLookaheadSec / stepSec);

    remSec  = zeros(1, nSats);
    stillUp = true(1, nSats);

    for k = 1:maxSteps
        if ~any(stillUp), break; end
        tProbe = tNow + seconds(k * stepSec);
        try
            if gsFirst
                [~, elvec, ~] = aer(gs, sats, tProbe);
            else
                [~, elvec, ~] = aer(sats, gs, tProbe);
            end
        catch
            break
        end
        stillUp = stillUp & (elvec(:)' >= minEl);
        remSec(stillUp) = remSec(stillUp) + stepSec;
    end
end

function orbitNum = estimateOrbitNumber(tleEpoch, t, n_rev_day, revAtEpoch)
    dt_days  = days(t - tleEpoch);
    orbitNum = floor(revAtEpoch + n_rev_day .* dt_days);
end

function buildFormattedExcel(handoverTimeline, handoverTable, sampleTime, ...
                             handoverMargin_deg, minElevation, outFile)

    nRows     = height(handoverTimeline);
    satIdx    = handoverTimeline.BestSatelliteIndex;
    timeVec   = handoverTimeline.Time;
    elevVec   = handoverTimeline.Elevation_deg;
    marginVec = handoverTimeline.HandoverMargin_deg;

    out_Num = {}; out_Active = {}; out_Plane = {}; out_SIP = {};
    out_Catalog = {}; out_Start = {}; out_End = {}; out_Duration = {};
    out_MaxElev = {}; out_MeanElev = {}; out_Margin = {};

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
        out_Margin{end+1,1}   = marginVec(segS);

        i = j;
    end

    reportTable = table( ...
        cell2mat(out_Num), out_Active, cell2mat(out_Plane), ...
        cell2mat(out_SIP), cell2mat(out_Catalog), out_Start, out_End, ...
        cell2mat(out_Duration), cell2mat(out_MaxElev), ...
        cell2mat(out_MeanElev), cell2mat(out_Margin), ...
        'VariableNames', { ...
            'HandoverNumber', 'ActiveSatellite', 'PlaneNumber', ...
            'SatelliteInPlane', 'CatalogNumber', 'StartTime', 'EndTime', ...
            'Duration_sec', 'MaxElevation_deg', 'MeanElevation_deg', ...
            'HandoverMargin_deg'});

    if exist(outFile, 'file'), delete(outFile); end
    writetable(reportTable, outFile, 'Sheet', 'Handover Summary');
end