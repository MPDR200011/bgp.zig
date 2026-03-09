import logging
import traceback

from docker import APIClient, DockerClient
from pyre_extensions import none_throws

import cluster_manager.drivers.docker.local_network_spec as spec
from cluster_manager.configuration.models import TestingConfiguration
from cluster_manager.drivers.base import BaseDriver, BaseHelper
from cluster_manager.drivers.docker.driver import LocalDockerDriver
from cluster_manager.drivers.docker.network_builder import (
    LocalNetwork,
    LocalNetworkBuilder,
)
from cluster_manager.drivers.running_network_spec import DriverData


class LocalDockerHelper(BaseHelper):
    client: DockerClient
    api_client: APIClient

    def __init__(self):
        self.client = DockerClient(base_url='unix:///var/run/docker.sock')
        self.api_client = APIClient(base_url='unix:///var/run/docker.sock')

    def _run_builder(self, config: TestingConfiguration) -> LocalNetwork:
        builder = LocalNetworkBuilder(self.client, self.api_client, config.topology)
        return builder.start_network()
    
    def build_network(self, config: TestingConfiguration) -> DriverData:
        local_network = self._run_builder(config)

        try:
            return DriverData(
                type=LocalDockerDriver.__name__,
                data=spec.LocalDockerNetworkSpec(
                    network=spec.LocalNetworkInfo(
                        network_name=none_throws(local_network.network.name),
                        network_id=none_throws(local_network.network.id)
                    ),
                    nodes=[
                        spec.LocalNodeInfo(
                            node_name=node_name,
                            container_id=none_throws(container.id)
                        ) for node_name, container in local_network.containers.items()
                    ]
                )
            )
        except Exception as e:
            logging.error(f"Error creating driver data: ${traceback.format_exc()}")
            LocalNetworkBuilder.teardown_network(local_network)
            raise e

    def _parse_driver_data(self, data: DriverData) -> LocalNetwork:
        if data.type != LocalDockerDriver.__name__:
            raise ValueError(f'Invalid driver type: {data.type}')

        driver_data = spec.LocalDockerNetworkSpec.model_validate(data.data)
        return LocalNetwork(
            network=self.client.networks.get(driver_data.network.network_id),
            containers={
                node.node_name: self.client.containers.get(node.container_id) for node in driver_data.nodes
            }
        )

    def get_driver(self, data: DriverData) -> BaseDriver:
        local_network = self._parse_driver_data(data)
        return LocalDockerDriver(self.client, self.api_client, local_network)

    def teardown_network(self, data: DriverData):
        local_network = self._parse_driver_data(data)
        LocalNetworkBuilder.teardown_network(local_network)
