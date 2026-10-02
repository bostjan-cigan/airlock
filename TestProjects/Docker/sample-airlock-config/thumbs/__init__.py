"""Video thumbnails with ffmpeg."""
import shutil
import subprocess
from pathlib import Path


def ffmpeg():
    path = shutil.which("ffmpeg")
    if not path:
        raise RuntimeError("ffmpeg isn't installed")
    return path


def make_thumbnail(video: Path, out: Path, at: float = 1.0, width: int = 320) -> Path:
    """Writes a PNG frame from `video` at `at` seconds, `width` pixels wide."""
    subprocess.run(
        [ffmpeg(), "-loglevel", "error", "-y", "-ss", str(at), "-i", str(video),
         "-frames:v", "1", "-vf", f"scale={width}:-1", str(out)],
        check=True,
    )
    return out


def sample_video(out: Path, seconds: int = 3) -> Path:
    """A generated test pattern, so the tests need no sample files."""
    subprocess.run(
        [ffmpeg(), "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc=duration={seconds}:size=640x360:rate=10", str(out)],
        check=True,
    )
    return out
