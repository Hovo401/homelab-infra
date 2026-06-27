param([Parameter(ValueFromRemainingArguments)]$a)
if (-not $a) { $a = @('ansible-playbook','site.yml','--ask-become-pass') }
elseif ($a[0] -like '-*') { $a = @('ansible-playbook','site.yml','--ask-become-pass') + $a }

$image = 'willhallonline/ansible:2.18-ubuntu-24.04'
$ssh = Join-Path $env:USERPROFILE '.ssh'
$fix = 'mkdir -p /root/.ssh; cp -f /root/.ssh-host/* /root/.ssh/ 2>/dev/null; chmod 700 /root/.ssh; chmod 600 /root/.ssh/* 2>/dev/null; exec "$@"'

docker run --rm -it -v "${PSScriptRoot}:/work" -v "${ssh}:/root/.ssh-host:ro" `
  -e ANSIBLE_CONFIG=/work/ansible.cfg -w /work $image `
  sh -c $fix -- @a
