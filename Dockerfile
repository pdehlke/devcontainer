# syntax=docker/dockerfile:1.18

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TARGETARCH
ARG CHEZMOI_VERSION=2.71.1
ARG CHEZMOI_AMD64_SHA256=e1fb16c962644d57f4d451c324aa86163d00faf5d035500f41fb48943a66dfed
ARG CHEZMOI_ARM64_SHA256=6e88c8150d3d54533ba2f335a52c2ac7b67259c525ba0f19091fc078b6852154
ARG GITHUB_ED25519_KNOWN_HOSTS_LINE="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

USER root

RUN set -eux; \
	apt-get update; \
	DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
	age \
	bat \
	ca-certificates \
	curl \
	git \
	openssh-client \
	sudo \
	tmux \
	zoxide \
	zsh; \
	rm -rf /var/lib/apt/lists/*

RUN set -eux; \
	case "${TARGETARCH}" in \
	amd64) chezmoi_sha256="${CHEZMOI_AMD64_SHA256}" ;; \
	arm64) chezmoi_sha256="${CHEZMOI_ARM64_SHA256}" ;; \
	*) echo "unsupported target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
	esac; \
	archive="/tmp/chezmoi_${CHEZMOI_VERSION}_linux_${TARGETARCH}.tar.gz"; \
	curl --fail --location --show-error --silent \
	--output "${archive}" \
	"https://github.com/twpayne/chezmoi/releases/download/v${CHEZMOI_VERSION}/chezmoi_${CHEZMOI_VERSION}_linux_${TARGETARCH}.tar.gz"; \
	printf '%s  %s\n' "${chezmoi_sha256}" "${archive}" | sha256sum --check --strict; \
	tar --extract --gzip --file "${archive}" --directory /usr/local/bin chezmoi; \
	chmod 0755 /usr/local/bin/chezmoi; \
	chezmoi --version | grep --fixed-strings --quiet "chezmoi version v${CHEZMOI_VERSION}"; \
	rm -- "${archive}"

RUN set -eux; \
	test "$(id --user vscode)" = 1000; \
	test "$(id --group vscode)" = 1000; \
	groupmod --new-name pde vscode; \
	usermod \
	--login pde \
	--home /home/pde \
	--move-home \
	--shell /bin/zsh \
	vscode; \
	usermod --append --groups root pde; \
	printf '%s\n' 'pde ALL=(ALL:ALL) NOPASSWD:ALL' >/etc/sudoers.d/pde; \
	chmod 0440 /etc/sudoers.d/pde; \
	if [[ -e /etc/sudoers.d/vscode ]]; then rm -- /etc/sudoers.d/vscode; fi; \
	visudo --check --file=/etc/sudoers.d/pde

# Keep clone trust outside dotfiles-managed home so public apply cannot replace it.
RUN set -eux; \
	install --directory --owner=pde --group=pde --mode=0700 /home/pde/.ssh; \
	printf '%s\n' "${GITHUB_ED25519_KNOWN_HOSTS_LINE}" >/etc/ssh/github_known_hosts; \
	chmod 0444 /etc/ssh/github_known_hosts; \
	printf '%s\n' "${GITHUB_ED25519_KNOWN_HOSTS_LINE}" >/home/pde/.ssh/known_hosts; \
	chown pde:pde /home/pde/.ssh/known_hosts; \
	chmod 0600 /home/pde/.ssh/known_hosts

ENV HOME=/home/pde

USER pde
WORKDIR /home/pde

RUN  curl -s https://mise.run 2>/dev/null | sh && ${HOME}/.local/bin/mise activate
RUN --mount=type=ssh,required=true,uid=1000,gid=1000,mode=0600 \
	GIT_SSH_COMMAND='ssh -F /dev/null -o BatchMode=yes -o IdentityFile=none -o IdentitiesOnly=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/github_known_hosts' \
	git clone -- git@github.com:pdehlke/dotfiles.git /home/pde/.yadr

RUN DEBIAN_FRONTEND=noninteractive /home/pde/.yadr/install.sh

RUN --mount=type=ssh,required=true,uid=1000,gid=1000,mode=0600 \
	GIT_SSH_COMMAND='ssh -F /dev/null -o BatchMode=yes -o IdentityFile=none -o IdentitiesOnly=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/github_known_hosts' \
	git clone -- git@github.com:pdehlke/dotfiles-private.git /home/pde/.yadr-private

# Remove temporary chezmoi configuration in the same layer that consumes the secrets.
RUN --mount=type=secret,id=dotfiles_age_identity,required=true,uid=1000,gid=1000,mode=0400 \
	--mount=type=secret,id=dotfiles_age_recipient,required=true,uid=1000,gid=1000,mode=0400 \
	set -eu; \
	scratch="$(mktemp -d)"; \
	trap 'rm -rf "${scratch}"' EXIT; \
	chmod 0700 "${scratch}"; \
	config="${scratch}/chezmoi-private.yaml"; \
	recipient="$(</run/secrets/dotfiles_age_recipient)"; \
	[[ "${recipient}" =~ ^age1[0-9a-z]+$ ]]; \
	umask 077; \
	printf '%s\n' \
	'workingTree: "/home/pde/.yadr-private"' \
	'sourceDir: "/home/pde/.yadr-private/root"' \
	'encryption: age' \
	'age:' \
	'  identity: "/run/secrets/dotfiles_age_identity"' \
	"  recipient: \"${recipient}\"" \
	'format: yaml' \
	'mode: file' \
	'verbose: true' >"${config}"; \
	chezmoi apply --config "${config}" --verbose --no-pager

RUN set -eu; \
	ssh_config=/home/pde/.ssh/config; \
	temporary_config="$(mktemp)"; \
	printf '%s\n' \
	'Host github.com' \
	'  HostName github.com' \
	'  User git' \
	'  IdentityAgent ~/.1password/agent.sock' \
	'  IdentitiesOnly no' \
	'  StrictHostKeyChecking yes' \
	'  UserKnownHostsFile ~/.ssh/known_hosts' \
	'' >"${temporary_config}"; \
	if [[ -f "${ssh_config}" ]]; then cat "${ssh_config}" >>"${temporary_config}"; fi; \
	chmod 0600 "${temporary_config}"; \
	mv -- "${temporary_config}" "${ssh_config}"; \
	known_hosts=/home/pde/.ssh/known_hosts; \
	touch "${known_hosts}"; \
	ssh-keygen -R github.com -f "${known_hosts}" >/dev/null; \
	ssh-keygen -R '[github.com]:22' -f "${known_hosts}" >/dev/null; \
	if [[ -e "${known_hosts}.old" ]]; then rm -- "${known_hosts}.old"; fi; \
	printf '%s\n' "${GITHUB_ED25519_KNOWN_HOSTS_LINE}" >>"${known_hosts}"; \
	chmod 0600 "${known_hosts}"; \
	install --directory --mode=0700 /home/pde/.1password; \
	ln --symbolic --force --no-dereference \
	/run/host-services/ssh-auth.sock \
	/home/pde/.1password/agent.sock; \
	effective_config="$(ssh -G github.com 2>/dev/null)"; \
	grep --fixed-strings --line-regexp --quiet \
	'identityagent /home/pde/.1password/agent.sock' <<<"${effective_config}"; \
	grep --fixed-strings --line-regexp --quiet \
	'stricthostkeychecking true' <<<"${effective_config}"; \
	grep --fixed-strings --line-regexp --quiet \
	'userknownhostsfile /home/pde/.ssh/known_hosts' <<<"${effective_config}"; \
	github_entry_count="$( \
	ssh-keygen -F github.com -f "${known_hosts}" | \
	grep --fixed-strings --line-regexp --count "${GITHUB_ED25519_KNOWN_HOSTS_LINE}" \
	)"; \
	test "${github_entry_count}" = 1; \
	if ssh-keygen -F '[github.com]:22' -f "${known_hosts}" >/dev/null; then exit 1; fi

RUN ${HOME}/.local/bin/mise use node neovim

ENV HOME=/home/pde

USER pde
WORKDIR /home/pde
CMD ["/bin/zsh", "-l"]
