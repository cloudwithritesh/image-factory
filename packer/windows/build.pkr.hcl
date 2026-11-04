# Windows build: same stages as Linux (patch, software, harden, SBOM,
# generalise), over WinRM instead of SSH. CI builds one target per job with
# -only=windows.<source>.
build {
  name = "windows"
  sources = [
    "source.amazon-ebs.windows",
    "source.azure-arm.windows",
  ]

  provisioner "shell-local" {
    inline = ["mkdir -p '${var.output_dir}/sbom'"]
  }

  # -- 1. Record what we're building on (shows up in the build log) -------------
  provisioner "powershell" {
    inline = [
      "$os = Get-CimInstance Win32_OperatingSystem",
      "Write-Output \"[bootstrap] $($os.Caption) $($os.Version) build $($os.BuildNumber), PowerShell $($PSVersionTable.PSVersion)\"",
    ]
  }

  # -- 2. Windows Update, software, hardening (Ansible over WinRM) -------------
  provisioner "ansible" {
    playbook_file = "${path.root}/../../ansible/windows.yml"
    galaxy_file   = "${path.root}/../../ansible/requirements.yml"
    roles_path    = "${path.root}/../../ansible/.galaxy/roles"
    use_proxy     = false # Ansible talks WinRM to the VM directly
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${path.root}/../../ansible/ansible.cfg",
      "ANSIBLE_FORCE_COLOR=1",
    ]
    extra_arguments = concat(
      [
        "--extra-vars", "@${var.ansible_vm_vars_file}",
        "--extra-vars", "packer_source_type=${source.type}",
        "--extra-vars", "ansible_connection=winrm",
        "--extra-vars", "ansible_winrm_scheme=https",
        "--extra-vars", "ansible_winrm_transport=ntlm",
        "--extra-vars", "ansible_winrm_server_cert_validation=ignore",
        "--extra-vars", "ansible_winrm_operation_timeout_sec=120",
        "--extra-vars", "ansible_winrm_read_timeout_sec=150",
      ],
      var.ansible_vm_skip_tags == "" ? [] : ["--skip-tags", var.ansible_vm_skip_tags],
    )
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # -- 3. SBOM ------------------------------------------------------------------
  provisioner "powershell" {
    environment_vars = [
      "SYFT_VERSION=${var.syft_version}",
      "IMAGE_NAME=${var.image_name}",
      "IMAGE_VERSION=${var.image_version}",
    ]
    script = "${path.root}/../../scripts/windows/generate-sbom.ps1"
  }

  provisioner "file" {
    direction   = "download"
    source      = "C:/Windows/Temp/sbom/sbom.cdx.json"
    destination = "${var.output_dir}/sbom/${var.image_name}-${var.image_version}-${source.type}.cdx.json"
  }

  provisioner "file" {
    direction   = "download"
    source      = "C:/Windows/Temp/sbom/sbom.spdx.json"
    destination = "${var.output_dir}/sbom/${var.image_name}-${var.image_version}-${source.type}.spdx.json"
  }

  # -- 4. Cleanup and generalise ---------------------------------------------------
  provisioner "powershell" {
    environment_vars = ["PACKER_SOURCE_TYPE=${source.type}"]
    script           = "${path.root}/../../scripts/windows/cleanup.ps1"
  }

  provisioner "powershell" {
    only   = ["azure-arm.windows"]
    script = "${path.root}/../../scripts/windows/sysprep-azure.ps1"
  }

  provisioner "powershell" {
    only   = ["amazon-ebs.windows"]
    script = "${path.root}/../../scripts/windows/sysprep-aws.ps1"
  }

  post-processor "manifest" {
    output     = "${var.output_dir}/manifest.json"
    strip_path = true
    custom_data = {
      image_name    = var.image_name
      image_version = var.image_version
      source_type   = source.type
    }
  }
}
