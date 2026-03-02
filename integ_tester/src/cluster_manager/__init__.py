import logging
import traceback
from pathlib import Path
from cluster_manager.drivers.docker.local_network_spec import LocalDockerNetworkSpec
from cluster_manager.drivers.docker.local_network_spec import SPEC_TYPE
from cluster_manager.drivers.running_network_spec import Spec
from cluster_manager.drivers.docker.driver import LocalDockerDriver
from cluster_manager.configuration.models import Node
from cluster_manager.configuration.models import Topology
from cluster_manager.configuration.models import DockerImage
import logging
import click
import ipaddress as ip

bird_image = DockerImage(image_name='bird-docker')

topology = Topology(
    name="test-topo",
    nodes={
        'bird1': Node(
            image=bird_image,
            name='bird1'
        ),
        'bird2': Node(
            image=bird_image,
            name='bird2'
        ),
    },
    links=[]
)
topology.link_nodes(
    a_node='bird1',
    a_intf=ip.ip_interface(address='192.168.0.2/30'),
    z_node='bird2',
    z_intf=ip.ip_interface(address='192.168.0.3/30'),
)

@click.group()
def main_command():
    pass

@click.command
@click.option('--project-root', default='.')
def start_cluster(project_root):
    driver = LocalDockerDriver(project_root=Path(project_root))
    spec = driver.standup_infra(topology)
    try:
        driver.start_nodes(spec)

        with open('/tmp/network_spec.json', 'w') as f:
            f.write(spec.model_dump_json())
    except Exception:
        logging.error(f'Error occurred: {traceback.format_exc()}')
        driver.stop(spec.spec_data)

@click.command
def stop_cluster():
    with open('/tmp/network_spec.json') as f:
        spec = Spec.model_validate_json(f.read())

    if spec.driver_type != SPEC_TYPE:
        raise ValueError(f'wrong driver type: {spec.driver_type}')

    specific_spec = LocalDockerNetworkSpec.model_validate(spec.spec_data)

    driver = LocalDockerDriver(project_root=Path('.'))
    driver.stop(specific_spec)

def build_cli():
    main_command.add_command(start_cluster)
    main_command.add_command(stop_cluster)

def main():
    logging.basicConfig(
        level=logging.DEBUG
    )
    logging.info("Starting CLI")

    build_cli()
    main_command()

