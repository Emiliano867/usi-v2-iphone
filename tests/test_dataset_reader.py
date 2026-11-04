from pathlib import Path

import pytest

from usi_stream.dataset_reader import export_episode


def test_export_cannot_write_inside_original_bag(tmp_path):
    bag=tmp_path/'raw'; bag.mkdir()
    original=bag/'sample.mcap'; original.write_bytes(b'preserve raw')
    with pytest.raises(ValueError,match='outside'):
        export_episode(bag,bag/'inspection')
    assert original.read_bytes()==b'preserve raw'
    assert not (bag/'inspection').exists()


def test_export_refuses_existing_output(tmp_path):
    bag=tmp_path/'raw'; bag.mkdir()
    output=tmp_path/'inspection'; output.mkdir()
    marker=output/'existing.txt'; marker.write_text('keep')
    with pytest.raises(FileExistsError): export_episode(bag,output)
    assert marker.read_text()=='keep'
