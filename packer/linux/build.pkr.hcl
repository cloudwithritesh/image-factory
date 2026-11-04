# One build, three sources. Every target gets the same provisioning, so
# AWS, Azure and Docker images built from one request have identical
# software and hardening. CI builds one target per job with -only.
build {
  name = "linux"
  sources = [
    "source.amazon-ebs.linux",
    "source.azure-arm.linux",
    "source.docker.linux",
  ]

  # -- 0. Local output folder for SBOMs ---------------------------------------
  provisioner "shell-local" {
    inline = ["mkdir -p '${var.output_dir}/sbom'"]
  }

  # -- 1. Bootstrap --------------------------------------------------------------
  # Make the target ready for Ansible: Python (minimal container images
  # lack it; SLES needs a newer one) and, on VMs, a finished cloud-init.
  # The script detects apt / dnf / microdnf / zypper by itself.
  provisioner "shell" {
    only             = ["docker.linux"]
    environment_vars = ["PKG_FAMILY=${var.pkg_family}", "IMAGE_KIND=container"]
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sh '{{ .Path }}'"
    script           = "${path.root}/../../scripts/linux/bootstrap.sh"
  }

  provisioner "shell" {
    except           = ["docker.linux"]
    environment_vars = ["PKG_FAMILY=${var.pkg_family}", "IMAGE_KIND=vm"]
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E sh '{{ .Path }}'"
    script           = "${path.root}/../../scripts/linux/bootstrap.sh"
  }

  # -- 2. Patch, install software, harden (Ansible) ------------------------------
  provisioner "ansible" {
    except        = ["docker.linux"]
    playbook_file = "${path.root}/../../ansible/image.yml"
    galaxy_file   = "${path.root}/../../ansible/requirements.yml"
    roles_path    = "${path.root}/../../ansible/.galaxy/roles"
    use_proxy     = false # connect straight to the VM; reboots work and it's faster
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${path.root}/../../ansible/ansible.cfg",
      "ANSIBLE_FORCE_COLOR=1",
    ]
    extra_arguments = concat(
      [
        "--extra-vars", "@${var.ansible_vm_vars_file}",
        "--extra-vars", "packer_source_type=${source.type}",
      ],
      local.ansible_python_args,
      var.ansible_vm_skip_tags == "" ? [] : ["--skip-tags", var.ansible_vm_skip_tags],
    )
  }

  provisioner "ansible" {
    only          = ["docker.linux"]
    playbook_file = "${path.root}/../../ansible/image.yml"
    galaxy_file   = "${path.root}/../../ansible/requirements.yml"
    roles_path    = "${path.root}/../../ansible/.galaxy/roles"
    user          = "root"
    use_proxy     = true # no SSH in a container; Packer proxies through docker exec
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${path.root}/../../ansible/ansible.cfg",
      "ANSIBLE_FORCE_COLOR=1",
      # Packer's proxy speaks the legacy scp protocol, not SFTP
      "ANSIBLE_SSH_TRANSFER_METHOD=scp",
      "ANSIBLE_SCP_EXTRA_ARGS=-O",
    ]
    extra_arguments = concat(
      [
        "--extra-vars", "@${var.ansible_container_vars_file}",
        "--extra-vars", "packer_source_type=${source.type}",
      ],
      var.ansible_python_interpreter == "" ? ["--extra-vars", "ansible_python_interpreter=/usr/bin/python3"] : local.ansible_python_args,
      var.ansible_container_skip_tags == "" ? [] : ["--skip-tags", var.ansible_container_skip_tags],
    )
  }

  # -- 3. SBOM (VMs) ----------------------------------------------------------------
  # Syft runs on the build VM after hardening, so the SBOM describes exactly
  # what ships. Container SBOMs are generated in CI from the pushed image.
  provisioner "shell" {
    except = ["docker.linux"]
    environment_vars = [
      "SYFT_VERSION=${var.syft_version}",
      "IMAGE_NAME=${var.image_name}",
      "IMAGE_VERSION=${var.image_version}",
    ]
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    script          = "${path.root}/../../scripts/vm/generate-sbom.sh"
  }

  provisioner "file" {
    except      = ["docker.linux"]
    direction   = "download"
    source      = "/tmp/sbom/sbom.cdx.json"
    destination = "${var.output_dir}/sbom/${var.image_name}-${var.image_version}-${source.type}.cdx.json"
  }

  provisioner "file" {
    except      = ["docker.linux"]
    direction   = "download"
    source      = "/tmp/sbom/sbom.spdx.json"
    destination = "${var.output_dir}/sbom/${var.image_name}-${var.image_version}-${source.type}.spdx.json"
  }

  # -- 4. Cleanup / generalise -------------------------------------------------------
  provisioner "shell" {
    except           = ["docker.linux"]
    environment_vars = ["PACKER_SOURCE_TYPE=${source.type}", "PKG_FAMILY=${var.pkg_family}"]
    execute_command  = "chmod +x {{ .Path }}; {{ .Vars }} sudo -E bash '{{ .Path }}'"
    script           = "${path.root}/../../scripts/vm/cleanup.sh"
    skip_clean       = true # on Azure the build user is deleted by waagent -deprovision+user
  }

  provisioner "shell" {
    only             = ["docker.linux"]
    environment_vars = ["PKG_FAMILY=${var.pkg_family}"]
    script           = "${path.root}/../../scripts/container/cleanup.sh"
  }

  # -- Post-processing -----------------------------------------------------------
  post-processor "manifest" {
    output     = "${var.output_dir}/manifest.json"
    strip_path = true
    custom_data = {
      image_name    = var.image_name
      image_version = var.image_version
      source_type   = source.type
    }
  }

  post-processors {
    post-processor "docker-tag" {
      only       = ["docker.linux"]
      repository = var.docker_repository
      tags       = ["candidate-${var.image_version}"]
    }
    post-processor "docker-push" {
      only           = ["docker.linux"]
      login          = true
      login_server   = var.docker_registry
      login_username = var.docker_registry_username
      login_password = var.docker_registry_password
    }
  }
}
