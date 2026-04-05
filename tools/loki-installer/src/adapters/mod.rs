//! Deployment adapter selection and shared test sinks.

mod cfn;
mod terraform;

use crate::core::{DeployAdapter, InstallEvent, InstallEventSink};

pub use cfn::CfnAdapter;
pub use terraform::TerraformAdapter;

pub fn adapter_for_method(method: crate::core::DeployMethodId) -> Box<dyn DeployAdapter> {
    match method {
        crate::core::DeployMethodId::Cfn => Box::new(CfnAdapter),
        crate::core::DeployMethodId::Terraform => Box::new(TerraformAdapter),
    }
}

#[derive(Default)]
pub struct NoopEventSink {
    pub events: Vec<InstallEvent>,
}

#[async_trait::async_trait]
impl InstallEventSink for NoopEventSink {
    async fn emit(&mut self, event: InstallEvent) {
        self.events.push(event);
    }
}
