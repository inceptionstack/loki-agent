use loki_installer::core::{DeployMethodId, ManifestRepository};
use std::collections::BTreeSet;
use std::fs;

#[test]
fn installer_manifests_load_and_validate_from_repo_yaml() {
    let repo = ManifestRepository::discover().expect("repo discovery");
    let packs = repo.load_all_packs().expect("load packs");

    assert!(!packs.is_empty(), "expected installer packs");

    let mut seen_profiles = BTreeSet::new();
    for pack in packs {
        pack.validate_contract().expect("valid pack manifest");
        assert_eq!(
            repo.root()
                .join("packs")
                .join(&pack.id)
                .join("manifest.yaml")
                .exists(),
            true,
            "pack {} should map to packs/<id>/manifest.yaml",
            pack.id
        );

        for profile in repo
            .load_profiles_for_pack(&pack)
            .expect("profiles for pack")
        {
            profile.validate_contract().expect("valid profile manifest");
            assert!(
                profile.supported_packs.contains(&pack.id),
                "profile {} should support pack {}",
                profile.id,
                pack.id
            );
            seen_profiles.insert(profile.id.clone());
        }

        for method in repo.load_methods_for_pack(&pack).expect("methods for pack") {
            method.validate_contract().expect("valid method manifest");
            assert!(
                pack.supported_methods.contains(&method.id),
                "method {} should be allowed by pack {}",
                method.id,
                pack.id
            );
        }
    }

    assert!(seen_profiles.contains("builder"));
    assert!(seen_profiles.contains("account_assistant"));
    assert!(seen_profiles.contains("personal_assistant"));
}

#[test]
fn method_manifests_load_from_actual_yaml_files() {
    let repo = ManifestRepository::discover().expect("repo discovery");

    repo.load_method(DeployMethodId::Cfn)
        .expect("load cfn method")
        .validate_contract()
        .expect("valid cfn method");
    repo.load_method(DeployMethodId::Terraform)
        .expect("load terraform method")
        .validate_contract()
        .expect("valid terraform method");
}

#[test]
fn every_pack_directory_with_installer_content_has_a_contract_manifest() {
    let repo = ManifestRepository::discover().expect("repo discovery");
    let packs_dir = repo.root().join("packs");

    let mut discovered_pack_ids = BTreeSet::new();
    for entry in fs::read_dir(&packs_dir).expect("read packs dir") {
        let entry = entry.expect("pack dir entry");
        if !entry.path().is_dir() {
            continue;
        }

        let install_script = entry.path().join("install.sh");
        let manifest = entry.path().join("manifest.yaml");
        if !install_script.exists() {
            continue;
        }

        assert!(
            manifest.exists(),
            "expected {} to exist for pack directory {}",
            manifest.display(),
            entry.file_name().to_string_lossy()
        );

        let pack = repo
            .load_pack(&entry.file_name().to_string_lossy())
            .expect("load pack manifest");
        pack.validate_contract().expect("valid pack manifest");
        discovered_pack_ids.insert(pack.id);
    }

    assert!(discovered_pack_ids.contains("bedrockify"));
    assert!(discovered_pack_ids.contains("openclaw"));
    assert!(discovered_pack_ids.contains("nemoclaw"));
}
