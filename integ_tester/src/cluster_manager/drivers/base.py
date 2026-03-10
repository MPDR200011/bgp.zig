from cluster_manager.configuration.models import Node
from docker.models.containers import ExecResult
from typing import List
from abc import abstractmethod, ABC
from pathlib import Path
import io

class BaseHelper(ABC):
    pass

class BaseDriver(ABC):
    @abstractmethod
    def install_file(self, node: Node, location: Path, contents_stream: io.IOBase):
        pass

    @abstractmethod
    def run_cmd(self, node: Node, cmd: str | List[str], wait: bool = True) -> ExecResult:
        pass
