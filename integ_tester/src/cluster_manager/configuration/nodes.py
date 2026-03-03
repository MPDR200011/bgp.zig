from cluster_manager.drivers.base import DriverContainer
from abc import abstractmethod
from abc import ABC
from dataclasses import dataclass

@dataclass
class Node(ABC):
    image_name: str
    name: str

    @abstractmethod
    def setup(self, container: DriverContainer):
        pass

