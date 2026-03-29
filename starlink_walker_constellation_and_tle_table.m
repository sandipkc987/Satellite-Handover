%%STARLINK FIRST SHELL WALKER-DELTA + TLE TABLE
% =========================================================================
% PURPOSE
% =========================================================================
% This script creates an idealized Starlink first-shell Walker-Delta
% constellation using Starlink-1019 as the reference / handler satellite.
%
% It also creates a metadata table named "tleTable" that stores the modeled
% satellite information for the entire shell.
%
% =========================================================================
% IMPORTANT MODELING NOTE
% =========================================================================
% Instead of downloading 1584 real TLEs from Space-Track.
% We are:
%   1) taking Starlink-1019 as a reference orbit
%   2) extracting shell-defining parameters from it
%   3) generating an ideal Walker-Delta shell mathematically
%
% Therefore:
%   - the constellation is synthetic / modeled
%   - tleTable is a modeled shell table
%   - only the handler keeps the real reference NORAD ID: 44724
%
% =========================================================================
% WALKER-DELTA SHELL USED
% =========================================================================
% Inclination  = 53.0546 deg
% Total sats   = 1584
% Planes       = 72
% Phasing      = 1
%
% Satellites per plane = 1584 / 72 = 22
%
% =========================================================================
% OUTPUTS OF THIS FILE
% =========================================================================
% 1) Full Walker-Delta constellation in main scenario
% 2) tleTable storing full modeled shell information
% 3) Excel export of tleTable
% 4) MAT-file export of workspace variables
% 5) Separate viewer scenario showing ONLY the handler satellite
%
% =========================================================================

clc;
clear;
close all;

%% ========================================================================
% 1) USER SETTINGS
% ========================================================================

% -------------------------------------------------------------------------
% Save folder requested by user
% -------------------------------------------------------------------------
saveFolder = 'C:\Users\sandy\Downloads\Handover';

% Create folder if it does not already exist
if ~exist(saveFolder, 'dir')
    mkdir(saveFolder);
end

% Output file names
excelFileName = fullfile(saveFolder, 'starlink_first_shell_tleTable.xlsx');
matFileName   = fullfile(saveFolder, 'starlink_first_shell_workspace.mat');

% -------------------------------------------------------------------------
% Simulation time settings
% -------------------------------------------------------------------------
% User requested start time: 25 Dec 2025
%startTime = datetime(2025,12,25,0,0,0,'TimeZone','UTC');

% Keep a short duration for first-file testing and visualization
%stopTime  = datetime(2025,12,25,3,0,0,'TimeZone','UTC');
startTime = datetime(2025,8,20,0,0,0,'TimeZone','UTC');
stopTime  = datetime(2025,8,20,3,0,0,'TimeZone','UTC');

%stopTime  = datetime(2025,8,21,0,0,0,'TimeZone','UTC');

% Scenario propagation step
sampleTime = 30;   % seconds

% -------------------------------------------------------------------------
% Viewer control
% -------------------------------------------------------------------------
showViewer = true;

%% ========================================================================
% 2) STARLINK-1019 REFERENCE VALUES
% ========================================================================
% These are the reference values used to define the shell geometry.

refSatName   = "STARLINK-1019";
refNoradID   = 44724;

% TLE epoch fields for the reference satellite
epochYear2   = 21;
epochDayFrac = 229.3717732;

% Reference orbital values from Starlink-1019
inclination_deg = 53.0546;
raan_ref_deg    = 102.5261;
ecc_ref         = 0.0002146;
argPerigee_deg  = 68.2315;
meanAnomaly_deg = 291.8902;
meanMotion_rev_per_day = 15.06408494;
revAtEpoch      = 97740;

%% ========================================================================
% 3) CONVERT TLE EPOCH TO DATETIME
% ========================================================================

if epochYear2 >= 57
    epochYear = 1900 + epochYear2;
else
    epochYear = 2000 + epochYear2;
end

tleEpoch = datetime(epochYear,1,1,0,0,0,'TimeZone','UTC') + days(epochDayFrac - 1);

%% ========================================================================
% 4) COMPUTE ORBITAL RADIUS FROM MEAN MOTION
% ========================================================================
% For a near-circular orbit, semi-major axis is used as orbital radius.

mu = 3.986004418e14;   % Earth gravitational parameter [m^3/s^2]
n_rad_s = meanMotion_rev_per_day * 2*pi / 86400;
orbitalRadius_m = (mu / n_rad_s^2)^(1/3);

%% ========================================================================
% 5) COMPUTE INITIAL ARGUMENT OF LATITUDE
% ========================================================================
% For near-circular orbit:
%   argument of latitude ~= argument of perigee + mean anomaly

argLatitude0_deg = mod(argPerigee_deg + meanAnomaly_deg, 360);

%% ========================================================================
% 6) WALKER-DELTA CONSTELLATION PARAMETERS
% ========================================================================

totalSatellites = 1584;
numberOfPlanes  = 72;
phasingFactor   = 1;

satellitesPerPlane = totalSatellites / numberOfPlanes;

if abs(round(satellitesPerPlane) - satellitesPerPlane) > 1e-12
    error('Total satellites must be divisible by number of planes.');
end

satellitesPerPlane = round(satellitesPerPlane);

% Walker angular spacings used for metadata reconstruction
planeSpacing_deg   = 360 / numberOfPlanes;
inPlaneSpacing_deg = 360 / satellitesPerPlane;
phasePerPlane_deg  = phasingFactor * 360 / totalSatellites;

%% ========================================================================
% 7) CREATE MAIN SATELLITE SCENARIO
% ========================================================================
% This scenario contains the FULL Walker-Delta constellation.
% It is used for data creation and for later access/visibility analysis.

sc = satelliteScenario(startTime, stopTime, sampleTime);

%% ========================================================================
% 8) CREATE FULL WALKER-DELTA CONSTELLATION
% ========================================================================
% MATLAB creates all satellites in the shell.
% We keep our own research labels in tleTable instead of renaming the
% satellite objects after creation.

walkerSats = walkerDelta( ...
    sc, ...
    orbitalRadius_m, ...
    inclination_deg, ...
    totalSatellites, ...
    numberOfPlanes, ...
    phasingFactor, ...
    RAAN = raan_ref_deg, ...
    ArgumentOfLatitude = argLatitude0_deg, ...
    Name = "StarlinkShell" ...
    );

numSat = numel(walkerSats);

fprintf('------------------------------------------------------------\n');
fprintf('Walker-Delta constellation created successfully.\n');
fprintf('Total satellites created: %d\n', numSat);
fprintf('Planes: %d\n', numberOfPlanes);
fprintf('Satellites per plane: %d\n', satellitesPerPlane);
fprintf('Start time: %s\n', char(startTime));
fprintf('Stop time : %s\n', char(stopTime));
fprintf('------------------------------------------------------------\n\n');

%% ========================================================================
% 9) BUILD FULL CONSTELLATION METADATA / TLE TABLE
% ========================================================================
% Naming convention for the paper:
%   HANDLE STARLINK-1019 P01-S01 #44724
%   STARLINK-1019 P01-S02
%   ...
%   STARLINK-1019 P72-S22
%
% We also create synthetic catalog numbers for internal bookkeeping.
% Only the handler uses the real NORAD ID 44724.

globalID        = (1:numSat).';
planeNumber     = zeros(numSat,1);
satInPlane      = zeros(numSat,1);
satLabel        = strings(numSat,1);
isHandler       = false(numSat,1);
catalogNumber   = zeros(numSat,1);

% Synthetic catalog numbering base for non-handler satellites
syntheticCatalogBase = 44000;

% Reconstructed geometry values for each Walker shell member
raan_deg_array   = zeros(numSat,1);
argLat_deg_array = zeros(numSat,1);

idx = 0;
for p = 1:numberOfPlanes
    for s = 1:satellitesPerPlane
        idx = idx + 1;

        planeNumber(idx) = p;
        satInPlane(idx)  = s;

        if idx == 1
            isHandler(idx) = true;
            catalogNumber(idx) = refNoradID;
            satLabel(idx) = sprintf("HANDLE %s P%02d-S%02d #%d", ...
                refSatName, p, s, refNoradID);
        else
            isHandler(idx) = false;
            catalogNumber(idx) = syntheticCatalogBase + idx;
            satLabel(idx) = sprintf("%s P%02d-S%02d", ...
                refSatName, p, s);
        end

        % Reconstruct Walker geometry for metadata table
        planeIdx0 = p - 1;
        satIdx0   = s - 1;

        raan_deg_array(idx) = mod(raan_ref_deg + planeIdx0 * planeSpacing_deg, 360);
        argLat_deg_array(idx) = mod(argLatitude0_deg + ...
                                    satIdx0 * inPlaneSpacing_deg + ...
                                    planeIdx0 * phasePerPlane_deg, 360);
    end
end

% Repeat reference/shell values for full table completeness
orbitRadius_m_col      = repmat(orbitalRadius_m, numSat, 1);
inclination_deg_col    = repmat(inclination_deg, numSat, 1);
eccentricity_col       = repmat(ecc_ref, numSat, 1);
argPerigee_deg_col     = repmat(argPerigee_deg, numSat, 1);
meanMotion_col         = repmat(meanMotion_rev_per_day, numSat, 1);
phasingFactor_col      = repmat(phasingFactor, numSat, 1);
numPlanes_col          = repmat(numberOfPlanes, numSat, 1);
satPerPlane_col        = repmat(satellitesPerPlane, numSat, 1);
revAtEpoch_col         = repmat(revAtEpoch, numSat, 1);
tleEpoch_col           = repmat(tleEpoch, numSat, 1);
epochYear_col          = repmat(epochYear, numSat, 1);
epochDayFrac_col       = repmat(epochDayFrac, numSat, 1);

%% ========================================================================
% 10) CREATE TLE TABLE
% ========================================================================
% This is the main metadata table for later files.

tleTable = table( ...
    globalID, ...
    isHandler, ...
    catalogNumber, ...
    satLabel, ...
    planeNumber, ...
    satInPlane, ...
    orbitRadius_m_col, ...
    inclination_deg_col, ...
    eccentricity_col, ...
    raan_deg_array, ...
    argPerigee_deg_col, ...
    argLat_deg_array, ...
    meanMotion_col, ...
    phasingFactor_col, ...
    numPlanes_col, ...
    satPerPlane_col, ...
    epochYear_col, ...
    epochDayFrac_col, ...
    tleEpoch_col, ...
    revAtEpoch_col, ...
    'VariableNames', { ...
        'GlobalID', ...
        'IsHandler', ...
        'CatalogNumber', ...
        'SatelliteLabel', ...
        'PlaneNumber', ...
        'SatelliteInPlane', ...
        'OrbitalRadius_m', ...
        'Inclination_deg', ...
        'Eccentricity', ...
        'RAAN_deg', ...
        'ArgumentOfPerigee_deg', ...
        'ArgumentOfLatitude_deg', ...
        'MeanMotion_rev_per_day', ...
        'PhasingFactor', ...
        'NumberOfPlanes', ...
        'SatellitesPerPlane', ...
        'EpochYear', ...
        'EpochDayFraction', ...
        'TLEEpoch', ...
        'RevAtEpoch' ...
        } ...
    );

%% ========================================================================
% 11) DISPLAY SAMPLE ROWS
% ========================================================================

disp('First 15 rows of tleTable:');
disp(tleTable(1:15,:));

handlerRow = tleTable(tleTable.IsHandler == true, :);

fprintf('\nHandler satellite entry:\n');
disp(handlerRow);

fprintf('Unique planes in shell: %d\n', numel(unique(tleTable.PlaneNumber)));
fprintf('Satellites per plane  : %d\n', satellitesPerPlane);

%% ========================================================================
% 12) EXPORT TABLE TO EXCEL
% ========================================================================

try
    writetable(tleTable, excelFileName, 'Sheet', 'TLE_Table');
    fprintf('\nExcel table exported successfully:\n%s\n', excelFileName);
catch ME
    warning('Excel export failed: %s', ME.message);
end

%% ========================================================================
% 13) SAVE MATLAB WORKSPACE DATA
% ========================================================================

save(matFileName, ...
    'sc', 'walkerSats', 'tleTable', ...
    'startTime', 'stopTime', 'sampleTime', ...
    'refSatName', 'refNoradID', ...
    'tleEpoch', 'orbitalRadius_m', ...
    'inclination_deg', 'raan_ref_deg', 'argLatitude0_deg', ...
    'totalSatellites', 'numberOfPlanes', 'satellitesPerPlane', ...
    'phasingFactor');

fprintf('\nMAT-file saved successfully:\n%s\n', matFileName);

%% ========================================================================
% 14) VIEWER SCENARIO: SHOW ONLY THE HANDLER SATELLITE
% ========================================================================
% The main scenario contains all 1584 satellites for data generation.
% For visualization right now, user requested to show ONLY the handler.
%
% So we build a separate lightweight scenario with just one satellite:
%   HANDLE STARLINK-1019 P01-S01 #44724

if showViewer
    scView = satelliteScenario(startTime, stopTime, sampleTime);

    handlerSat = satellite( ...
        scView, ...
        orbitalRadius_m, ...
        ecc_ref, ...
        inclination_deg, ...
        raan_ref_deg, ...
        argPerigee_deg, ...
        argLatitude0_deg, ...
        Name = "HANDLE STARLINK-1019 #44724" ...
        );

    fprintf('\nOpening viewer with ONLY the handler satellite...\n');
    satelliteScenarioViewer(scView);
    play(scView);
end

%% ========================================================================
