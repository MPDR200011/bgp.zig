from typing import Mapping
from cluster_manager import MyTestingConfiguration
from pydantic import ModelWrapValidatorHandler
from typing import Self
from pydantic import model_validator
from pydantic_core.core_schema import SerializerFunctionWrapHandler
from pydantic import model_serializer
from typing import Type
from cluster_manager.configuration.models import TestingConfiguration
from typing import Any
from pydantic import BaseModel

TEST_CONFIGS: Mapping[str, Type[TestingConfiguration]] = {
    MyTestingConfiguration.__name__: MyTestingConfiguration
}

#class SpecConfig(BaseModel):
#    config_data: TestingConfiguration
#
#    @model_serializer(mode='wrap')
#    def serialize_model(self, handler: SerializerFunctionWrapHandler) -> dict[str, object]:
#        return {
#            'type': self.config_data.__class__.__name__,
#            'data': self.config_data.serialize()
#        }
#
#    @model_validator(mode='wrap')
#    @classmethod
#    def validate_model(cls, data: Any, handler: ModelWrapValidatorHandler[Self]) -> Self:
#        config_class = TEST_CONFIGS[data['type']]
#        return SpecConfig(
#            config_data=config_class.deserialize(data['data'])
#        )

class DriverData(BaseModel):
    type: str
    data: Any

class Spec(BaseModel):
    #test_config: SpecConfig
    driver_data: DriverData
