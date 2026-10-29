import unittest
try:
    from usi_stream import collection_state as s
except ImportError:
    s = None


class CollectionStateTests(unittest.TestCase):
    def test_implementation_available(self): self.assertIsNotNone(s, 'state implementation missing')

    def calibration(self):
        return s.PressureCalibration('cal-A', tuple(s.ChamberCalibration(i, i, 60.0, 70.0, 10) for i in range(3)))

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_unknown_invalid_uncalibrated_stale_and_quality_mapping(self):
        model = s.SealModel(self.calibration(), stale_ns=250)
        self.assertEqual(model.snapshot(0).states, ('unknown',)*3)
        model.update([50,50,50], quality_mask=5, received_ns=1)
        self.assertEqual(model.snapshot(11).states, ('sealed','invalid','sealed'))
        self.assertEqual(model.snapshot(11).aggregate, 'unavailable')
        self.assertEqual(model.snapshot(252).states, ('stale',)*3)
        model.update([50,50,50], quality_mask=7, received_ns=253)
        self.assertEqual(model.snapshot(253).states, ('unsealed',)*3) # persistence restarts after stale
        plain = s.SealModel(None)
        plain.update([50,50,50], quality_mask=7, received_ns=1)
        self.assertEqual(plain.snapshot(1).states, ('uncalibrated',)*3)
        mapped = s.SealModel(s.PressureCalibration('mapped', (
            s.ChamberCalibration(2,0,60,70,0), s.ChamberCalibration(0,1,60,70,0), s.ChamberCalibration(1,2,60,70,0))))
        mapped.update([50,50,50], quality_mask=1, received_ns=1)
        self.assertEqual(mapped.snapshot(1).states, ('invalid','sealed','invalid'))

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_hysteresis_persistence_and_all_known_aggregate(self):
        model = s.SealModel(self.calibration(), stale_ns=250)
        model.update([50,80,50], quality_mask=7, received_ns=0)
        self.assertEqual(model.snapshot(9).states, ('unsealed',)*3)
        self.assertEqual(model.snapshot(10).aggregate, 'partial')
        model.update([65,50,65], quality_mask=7, received_ns=11)
        self.assertEqual(model.snapshot(21).aggregate, 'full')
        model.update([75,75,75], quality_mask=7, received_ns=22)
        self.assertEqual(model.snapshot(31).aggregate, 'full')
        self.assertEqual(model.snapshot(32).aggregate, 'none')
        with self.assertRaises(ValueError): s.ChamberCalibration(0,0,70,60,0)
        with self.assertRaises(ValueError): s.PressureCalibration('bad', (s.ChamberCalibration(0,0,60,70,0),)*3)

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_trigger_is_independent_and_stale_unknown(self):
        trigger = s.TriggerModel(stale_ns=1000)
        self.assertEqual(trigger.state(0), 'unknown')
        trigger.update(pressed=False, received_ns=1)
        self.assertEqual(trigger.state(1), 'on')
        trigger.update(pressed=True, received_ns=2)
        self.assertEqual(trigger.state(2), 'off')
        self.assertEqual(trigger.state(1003), 'unknown')
        with self.assertRaises(ValueError): trigger.update(pressed=1, received_ns=3)

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_sequence_wrap_duplicates_gaps_epochs_and_bounded_queue(self):
        history = s.SequenceHistory(modulus=2**32)
        self.assertEqual(history.observe('boot-A', 2**32-1).sequence, 2**32-1)
        self.assertEqual(history.observe('boot-A', 0).sequence, 2**32)
        self.assertEqual(history.observe('boot-A', 0).disposition, 'duplicate')
        self.assertEqual(history.observe('boot-A', 3).missing, (2**32+1, 2**32+3))
        self.assertEqual(history.observe('boot-A', 2).disposition, 'out_of_order')
        self.assertEqual(history.observe('boot-B', 0).disposition, 'new_epoch')
        self.assertEqual(history.observe('boot-A', 4).disposition, 'old_epoch')
        queue = s.BoundedQueue(1)
        self.assertTrue(queue.offer('pose1')); self.assertFalse(queue.offer('pose2'))
        self.assertEqual(queue.overflow_count, 1); self.assertEqual(queue.pop(), 'pose1')
        self.assertIsNone(queue.pop())

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_trial_only_host_ack_recording_idempotency_and_stale(self):
        model = s.TrialModel(host_stale_ns=2000)
        self.assertEqual(model.display_state(0), 'not_connected')
        model.begin_request('r','t')
        self.assertEqual(model.display_state(0), 'preparing')
        model.begin_request('r','t') # idempotent local submission
        self.assertTrue(model.apply_status(host_session_id='h', trial_id='t', revision=2,
                                          state='recording', verification='pending', received_ns=1))
        self.assertEqual(model.display_state(1), 'recording')
        self.assertEqual(model.display_state(2002), 'host_stale')
        self.assertFalse(model.apply_status(host_session_id='h', trial_id='t', revision=1,
                                           state='preparing', verification='pending', received_ns=2003))
        self.assertEqual(model.display_state(2003), 'host_stale')
        with self.assertRaises(ValueError): model.apply_status(host_session_id='h', trial_id='t', revision=3,
                                       state='saved', verification='pending', received_ns=2003)
        self.assertTrue(model.apply_status(host_session_id='h', trial_id='t', revision=4,
                                          state='saved', verification='passed', received_ns=2004))
        self.assertEqual(model.display_state(2004), 'saved')

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_identity_unknown_counters_and_terminal_trial_cannot_regress(self):
        self.assertIsNone(s.StreamCounters().writer_accepted_count)
        with self.assertRaises(ValueError): s.StreamCounters(source_count=True)
        with self.assertRaises(ValueError): s.SampleIdentity('pressures', 12, 'boot', 0)
        self.assertEqual(s.SampleIdentity('pressures','esp','boot',2**32).sequence,2**32)
        model=s.TrialModel(); model.begin_request('r','t')
        self.assertTrue(model.apply_status(host_session_id='h',trial_id='t',revision=4,state='saved',verification='passed',received_ns=1))
        self.assertFalse(model.apply_status(host_session_id='h',trial_id='t',revision=5,state='recording',verification='pending',received_ns=2))
        self.assertEqual(model.display_state(2),'saved')
        reboot=s.TrialModel(); reboot.begin_request('r','t')
        reboot.apply_status(host_session_id='a',trial_id='t',revision=2,state='recording',verification='pending',received_ns=1)
        self.assertFalse(reboot.apply_status(host_session_id='b',trial_id='t',revision=1,state='recording',verification='pending',received_ns=2))
        self.assertTrue(reboot.apply_status(host_session_id='a',trial_id='t',revision=2,state='recording',verification='pending',received_ns=3))
        self.assertTrue(reboot.apply_status(host_session_id='b',trial_id='t',revision=1,state='incomplete',verification='failed',received_ns=4))
        self.assertFalse(reboot.apply_status(host_session_id='a',trial_id='t',revision=3,state='recording',verification='pending',received_ns=5))

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_finalizing_and_terminal_ack_cannot_revert_to_recording(self):
        model=s.TrialModel();model.begin_request('r','t')
        model.apply_status(host_session_id='h',trial_id='t',revision=3,state='finalizing',verification='pending',received_ns=1)
        self.assertFalse(model.apply_status(host_session_id='h',trial_id='t',revision=4,state='recording',verification='pending',received_ns=2))
        self.assertTrue(model.apply_status(host_session_id='h',trial_id='t',revision=5,state='saved',verification='passed',received_ns=3))
        self.assertFalse(model.apply_status(host_session_id='new-host',trial_id='t',revision=2,state='recording',verification='pending',received_ns=4))

    @unittest.skipIf(s is None, 'missing state implementation')
    def test_replacement_host_can_prepare_explicit_new_trial_after_saved(self):
        model=s.TrialModel();model.begin_request('r1','t1')
        model.apply_status(host_session_id='h1',trial_id='t1',revision=4,state='saved',verification='passed',received_ns=1)
        model.begin_request('r2','t2')
        self.assertTrue(model.apply_status(host_session_id='h2',trial_id='t2',revision=1,state='preparing',verification='pending',received_ns=2))
        self.assertTrue(model.apply_status(host_session_id='h2',trial_id='t2',revision=2,state='recording',verification='pending',received_ns=3))
        self.assertFalse(model.apply_status(host_session_id='h3',trial_id='t2',revision=1,state='preparing',verification='pending',received_ns=4))
        self.assertFalse(model.apply_status(host_session_id='h3',trial_id='t2',revision=2,state='recording',verification='pending',received_ns=5))
