from typing import Dict
from pyre_extensions import JSON
from typing import Type
import io
import ipaddress as ip
import os
from pathlib import Path
from typing import List, Mapping, override

from cluster_manager.configuration.models import (
    Node,
    Service,
    TestingConfiguration,
    Topology,
)


class BirdService(Service):
    def __init__(self, node: Node):
        super().__init__(node)

    @override
    @classmethod
    def match_node(cls, node: Node) -> bool:
        return node.get('type') == 'bird'

    @override
    def get_files(self) -> Mapping[str, io.IOBase]:
        project_root = os.environ['PROJECT_ROOT']

        bird_config_dir = Path(project_root) / 'test_configs' / 'bird' / f'{self.node.name}.cfg'
        with io.open(bird_config_dir, mode='rb') as f:
            return {
                '/etc/bird/bird.conf': io.BytesIO(f.read())
            }

    @override
    def get_start_command(self) -> str | List[str]:
        return ['bird']

class BgpzService(Service):
    def __init__(self, node: Node):
        super().__init__(node)

    @override
    @classmethod
    def match_node(cls, node: Node) -> bool:
        return node.get('type') == 'bgpz'

    @override
    def get_files(self) -> Mapping[str, io.IOBase]:
        project_root = os.environ['PROJECT_ROOT']

        bird_config_dir = Path(project_root) / 'test_configs' / 'bgpz' / f'{self.node.name}.json'
        with io.open(bird_config_dir, mode='rb') as f:
            return {
                '/etc/bgpz/bgpz.json': io.BytesIO(f.read()),
                '/usr/bin/start-bgp': io.BytesIO("""
                #!/bin/bash

                bgpz -c /etc/bgpz/bgpz.json > /tmp/bgp.log
                """.encode())
            }

    @override
    def get_start_command(self) -> str | List[str]:
        return 'cat /usr/bin/start-bgp'

class MyTestingConfiguration(TestingConfiguration):
    _topology: Topology

    def __init__(self):
        topology = Topology(
            name="test-topo",
            nodes={
                'bird1': Node(
                    image_name='bird-docker',
                    name='bird1',
                    data={
                        'type': 'bird'
                    },
                ),
                'bird2': Node(
                    image_name='bird-docker',
                    name='bird2',
                    data={
                        'type': 'bird'
                    }
                ),
                'bgpz1': Node(
                    image_name='bgpz-docker',
                    name='bgpz1',
                    data={
                        'type': 'bgpz'
                    }
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
        topology.link_nodes(
            a_node='bird1',
            a_intf=ip.ip_interface(address='192.168.1.1/30'),
            z_node='bgpz1',
            z_intf=ip.ip_interface(address='192.168.1.2/30'),
        )

        self._topology = topology

    @override
    def get_services(self) -> List[Type[Service]]:
        return [
            BirdService,
            BgpzService
        ]

    @override
    @property
    def topology(self) -> Topology:
        return self._topology

    @override
    def deserialize(cls, data: Dict[str, JSON]) -> TestingConfiguration:
        return MyTestingConfiguration()

    @override
    def serialize(self) -> Dict[str, JSON]:
        return { }
