import io
import logging
import tarfile
import traceback
from pathlib import Path
from tarfile import TarInfo
from typing import List, override

import docker
from docker.models.containers import ExecResult
from pyre_extensions import none_throws

from cluster_manager.configuration.models import Node, TestingConfiguration
from cluster_manager.drivers.base import BaseDriver
from cluster_manager.drivers.docker.local_network_spec import (
    LocalDockerNetworkSpec,
    LocalNetworkInfo,
    LocalNodeInfo,
)
from cluster_manager.drivers.docker.network_builder import (
    LocalNetwork,
    LocalNetworkBuilder,
)
from cluster_manager.drivers.running_network_spec import Spec


class LocalDockerDriver(BaseDriver):
    client: docker.DockerClient
    api_client: docker.APIClient
    network: LocalNetwork

    def __init__(self, client: docker.DockerClient, api_client: docker.APIClient, network: LocalNetwork):
        self.client = client
        self.api_client = api_client
        self.network = network

    @override
    def install_file(self, node: Node, location: Path, contents_stream: io.IOBase):
        container = self.network.containers[node.name]

        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w|') as tar:
            all_contents = io.BytesIO(contents_stream.read())

            info = TarInfo(name=location.name)
            info.size = len(all_contents.getbuffer())
            tar.addfile(info, all_contents)

        container.put_archive(location.parent.as_posix(), stream.getvalue())

    @override
    def run_cmd(self, node: Node, cmd: str | List[str], wait: bool = True) -> ExecResult:
        container = self.network.containers[node.name]
        return container.exec_run(cmd, detach=not wait)

