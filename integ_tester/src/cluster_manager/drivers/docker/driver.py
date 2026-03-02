from tarfile import TarInfo
from pyre_extensions import none_throws
from pathlib import Path
from dataclasses import dataclass
from cluster_manager.drivers.docker.local_network_spec import LocalDockerNetworkSpec
import logging
import io
import tarfile

import docker
from docker.models.containers import Container

from cluster_manager.configuration.models import Topology
from cluster_manager.drivers.base import BaseDriver
from cluster_manager.drivers.docker.network_builder import LocalNetworkBuilder
from cluster_manager.drivers.running_network_spec import Spec


@dataclass
class LocalContainer:
    client: docker.DockerClient

    container: Container

    mount_location: Path

    def install_file(self, location: Path, contents_stream: io.IOBase):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w|') as tar:
            all_contents = io.BytesIO(contents_stream.read())

            info = TarInfo(name=location.name)
            info.size = len(all_contents.getbuffer())
            tar.addfile(info, all_contents)

        self.container.put_archive(location.parent.as_posix(), stream.getvalue())

class LocalDockerDriver(BaseDriver):
    client: docker.DockerClient
    api_client: docker.APIClient

    project_root: Path

    def __init__(self, project_root: Path):
        self.client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        self.api_client = docker.APIClient(base_url='unix:///var/run/docker.sock')
        self.project_root = project_root

    def standup_infra(self, topology: Topology) -> Spec:
        logging.info("Starting network")

        builder = LocalNetworkBuilder(self.client, self.api_client, topology)
        return builder.start_network()

    def start_nodes(self, spec: Spec):
        spec_data: LocalDockerNetworkSpec = spec.spec_data

        for node in spec_data.nodes:
            container = self.client.containers.get(node.container_id)
            local_container = LocalContainer(
                client=self.client,
                container=container,
                mount_location=Path(LocalNetworkBuilder.get_container_volume_location(none_throws(container.name)))
            )

            with io.open(self.project_root / 'test_configs' / 'bird' / f'{container.name}.cfg', mode='rb') as f:
                local_container.install_file(
                    Path('/etc/bird/bird.conf'),
                    f
                )
                result = local_container.container.exec_run(
                    cmd='bird',
                    detach=False,
                )
                print(result.output)

    def stop(self, spec: LocalDockerNetworkSpec):
        for node in spec.nodes:
            container = self.client.containers.get(node.container_id)
            container.stop()
            container.remove()

        network = self.client.networks.get(spec.network.network_id)
        network.remove()
