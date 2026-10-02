import struct
import sys

from thumbs import make_thumbnail, sample_video


def png_size(path):
    with open(path, "rb") as f:
        header = f.read(24)
    assert header[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", header[16:24])


def test_python_comes_from_the_settings_file():
    assert sys.version_info[:2] == (3, 13)


def test_thumbnail(tmp_path):
    video = sample_video(tmp_path / "in.mp4")
    thumb = make_thumbnail(video, tmp_path / "thumb.png", width=160)
    assert png_size(thumb) == (160, 90)
