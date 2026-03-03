from docker.models.containers import ExecResult
from typing import List
from abc import abstractmethod, ABC
from pathlib import Path
import io

class DriverContainer(ABC):
    @abstractmethod
    def install_file(self, location: Path, contents_stream: io.IOBase):
        pass

    @abstractmethod
    def run_cmd(self, cmd: str | List[str], wait: bool = True) -> ExecResult:
        pass

class BaseDriver(ABC):
    pass
