//! Manifest discovery and YAML loading for packs, profiles, and methods.

use crate::core::{DeployMethodId, MethodManifest, PackManifest, ProfileManifest};
use serde::de::DeserializeOwned;
use serde_yaml::Value;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("repo root not found from {0}")]
    RepoRootNotFound(String),
    #[error("manifest not found: {0}")]
    NotFound(String),
    #[error("failed to read {path}: {source}")]
    Read {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to parse {path}: {source}")]
    Parse {
        path: String,
        #[source]
        source: serde_yaml::Error,
    },
}

#[derive(Debug, Clone)]
pub struct ManifestRepository {
    root: PathBuf,
}

impl ManifestRepository {
    pub fn discover() -> Result<Self, ManifestError> {
        let cwd = std::env::current_dir().map_err(|err| ManifestError::Read {
            path: ".".into(),
            source: err,
        })?;

        for dir in cwd.ancestors() {
            if dir.join("packs").is_dir() && dir.join("profiles").is_dir() {
                return Ok(Self {
                    root: dir.to_path_buf(),
                });
            }
        }

        Err(ManifestError::RepoRootNotFound(cwd.display().to_string()))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn load_pack(&self, pack_id: &str) -> Result<PackManifest, ManifestError> {
        self.read_yaml(self.root.join("packs").join(pack_id).join("manifest.yaml"))
    }

    pub fn load_profile(&self, profile_id: &str) -> Result<ProfileManifest, ManifestError> {
        self.read_yaml(
            self.root
                .join("profiles")
                .join(format!("{profile_id}.yaml")),
        )
    }

    pub fn load_method(&self, method_id: DeployMethodId) -> Result<MethodManifest, ManifestError> {
        self.read_yaml(self.root.join("methods").join(format!("{method_id}.yaml")))
    }

    pub fn load_all_packs(&self) -> Result<Vec<PackManifest>, ManifestError> {
        let packs_dir = self.root.join("packs");
        let entries = fs::read_dir(&packs_dir).map_err(|err| ManifestError::Read {
            path: packs_dir.display().to_string(),
            source: err,
        })?;

        let mut manifests = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|err| ManifestError::Read {
                path: packs_dir.display().to_string(),
                source: err,
            })?;
            let manifest_path = entry.path().join("manifest.yaml");
            if !manifest_path.exists() {
                continue;
            }
            if !self.is_installer_manifest(&manifest_path)? {
                continue;
            }
            manifests.push(self.read_yaml::<PackManifest>(manifest_path)?);
        }
        manifests.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(manifests)
    }

    pub fn load_profiles_for_pack(
        &self,
        pack: &PackManifest,
    ) -> Result<Vec<ProfileManifest>, ManifestError> {
        let mut profiles = Vec::new();
        for profile_id in &pack.allowed_profiles {
            profiles.push(self.load_profile(profile_id)?);
        }
        profiles.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(profiles)
    }

    pub fn load_methods_for_pack(
        &self,
        pack: &PackManifest,
    ) -> Result<Vec<MethodManifest>, ManifestError> {
        let mut methods = Vec::new();
        for method_id in &pack.supported_methods {
            methods.push(self.load_method(*method_id)?);
        }
        methods.sort_by(|a, b| a.id.cmp(&b.id));
        Ok(methods)
    }

    fn read_yaml<T: DeserializeOwned>(&self, path: PathBuf) -> Result<T, ManifestError> {
        if !path.exists() {
            return Err(ManifestError::NotFound(path.display().to_string()));
        }
        let raw = fs::read_to_string(&path).map_err(|err| ManifestError::Read {
            path: path.display().to_string(),
            source: err,
        })?;
        serde_yaml::from_str(&raw).map_err(|err| ManifestError::Parse {
            path: path.display().to_string(),
            source: err,
        })
    }

    fn is_installer_manifest(&self, path: &Path) -> Result<bool, ManifestError> {
        let raw = fs::read_to_string(path).map_err(|err| ManifestError::Read {
            path: path.display().to_string(),
            source: err,
        })?;
        let value: Value = serde_yaml::from_str(&raw).map_err(|err| ManifestError::Parse {
            path: path.display().to_string(),
            source: err,
        })?;
        Ok(value.get("schema_version").is_some())
    }
}
