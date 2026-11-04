# Raw MCAP Episode Reader Implementation Plan

> Execute inline in the existing isolated worktree. The user requested direct work without subagents.

**Goal:** Inspect a real USI recording as the first stage toward suction-policy datasets, without inventing synchronized data or tool actions.

**Architecture:** A read-only streaming Jazzy MCAP reader exports scalar CSV streams and a JSON report into a new directory. Images remain in the original MCAP, referenced by a frame index. Unavailable calibration, clock alignment and suction-command semantics remain explicit training blockers.

**Tech stack:** Python 3.12, standard-library CSV/JSON, existing ROS 2 Jazzy and usi_collection_msgs. ROS imports stay lazy.

**Scope:** First task is book extraction from a crowded bookshelf; eventual robot FANUC CRX-10iA. The phone is not physically mounted yet. Robot control is being handled separately. This deliverable performs no robot communication, actuation, source-bag mutation, clock fitting or policy training.

## Task 1: Episode reader and inspection exports

**Files:** Create `usi_stream/dataset_reader.py`, `tests/test_dataset_reader.py`; add a real-MCAP test in `tests/ros/test_mcap_recording.py`.

- [x] Add failing tests importing `export_episode(bag_path, output_path)`. Assert output cannot be inside the raw bag or overwrite an existing directory. A real generated MCAP must yield frame, pose, pressure and trigger tables preserving source identity/time and quality bits.
- [x] Implement `export_episode(bag_path, output_path) -> dict`. Read one message at a time, write CSV rows without retaining image arrays, preserve the trial snapshot and raw clocks, and compare actual stream counts with any recorded verification manifest. Export `episode_report.json` with `training_ready: false` and concrete missing preprocessing requirements.
- [x] Add CLI `python3 -m usi_stream.dataset_reader BAG --output OUTPUT` and run focused tests. Expected: protected inputs unchanged, real records exported, no synthesized actions or changed timestamps.

## Task 2: Physical-data inspection and documentation

**Files:** Create `docs/policy-dataset.md`; update this plan's completion status.

- [x] Run the reader on the latest complete physical trial into `/home/emi-linux/usi_ws/analysis/dataset-inspection/`. Check valid/invalid pressure counts, calibration ID, camera/pose counts, clock exchanges and original trigger semantics against direct bag inspection.
- [x] Document invocation and output columns, next clock-alignment/tool-calibration/suction-action requirements, and the bookshelf/FANUC benchmark. Explain that CSV inspection exports are not a training-ready Zarr dataset.
- [x] Run the relevant Python/Jazzy suite and `git diff --check`, commit the implementation, and report the actual artifact path and next physical calibration requirement.

## Evidence

126 Python/Jazzy tests passed. Physical trial `trial-ba9afbf28f7511fe` exported with exact manifest counts: 1758 each RGB/depth/confidence/pose, 8438 pressures, 244 triggers and 175 clock exchanges. Pressure masks are 8408 fully valid triples and 30 C3-invalid triples. Invalid C3 rows retain the raw -100 centiPa value and leave its invalid kPa field blank. All 1758 poses are flagged limited tracking, and the report requires filtering/recollection for training. Older recorded seal labels are preserved and explicitly flagged for review. Export path is `/home/emi-linux/usi_ws/analysis/dataset-inspection/trial-ba9afbf28f7511fe`.
