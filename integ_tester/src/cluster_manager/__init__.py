from cluster_manager.configuration.concrete.my_config import MyTestingConfiguration
import logging
import traceback
from pathlib import Path
from cluster_manager.drivers.docker.local_network_spec import LocalDockerNetworkSpec
from cluster_manager.drivers.docker.local_network_spec import SPEC_TYPE
from cluster_manager.drivers.running_network_spec import Spec
from cluster_manager.drivers.docker.driver import LocalDockerDriver
import click


@click.group()
def main_command():
    pass

@click.command
@click.option('--project-root', default='.')
def start_cluster(project_root: str):
    config = MyTestingConfiguration(project_root)
    driver = LocalDockerDriver(project_root=Path(project_root))
    spec = driver.standup_infra(config.topology)
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

