import io
from pathlib import Path
from cluster_manager.drivers.base import DriverContainer
from cluster_manager.configuration.models import Topology
from typing import override
import ipaddress as ip
from cluster_manager.configuration.nodes import Node
from cluster_manager.configuration.models import TestingConfiguration

class BirdNode(Node):
    config_dir: Path

    def __init__(self, name: str, config_dir: Path):
        super().__init__('bird-docker', name)
        self.config_dir = config_dir

    @override
    def setup(self, container: DriverContainer):
        with io.open(self.config_dir / f'{self.name}.cfg', mode='rb') as f:
            container.install_file(
                Path('/etc/bird/bird.conf'),
                f
            )
            result = container.run_cmd(
                cmd='bird',
                wait=False,
            )
            print(result.output)

class MyTestingConfiguration(TestingConfiguration):
    _topology: Topology

    def __init__(self, project_root: str):
        super().__init__([
            BirdNode
        ])

        bird_config_dir = Path(project_root) / 'test_configs' / 'bird'

        topology = Topology(
            name="test-topo",
            nodes={
                'bird1': BirdNode(
                    name='bird1',
                    config_dir=bird_config_dir
                ),
                'bird2': BirdNode(
                    name='bird2',
                    config_dir=bird_config_dir
                ),
            },
            links=[]
        )
        topology.link_nodes(
            a_node='bird1',
            a_intf=ip.ip_interface(address='192.168.0.1/30'),
            z_node='bird2',
            z_intf=ip.ip_interface(address='192.168.0.2/30'),
        )

        self._topology = topology

    @override
    @property
    def topology(self) -> Topology:
        return self._topology
