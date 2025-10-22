Name:           pfcli
Version:        %{_version}
Release:        1%{?dist}
Summary:        port mapping cli with socat

License:        MIT
URL:            https://github.com/cylonchau/pfcli

# Pre-built files
Source0:        pfcli.sh
Source1:        README.md
Source2:        LICENSE

BuildArch:      x86_64

BuildRequires:  shc, gcc
Requires:       socat, bash

%description
Linux port mapping cli with socat

%prep

%build
# Compile kubee.sh to binary using shc
shc -f %{SOURCE0} -o pfcli -r

%install
# Install binary
install -D -m 755 pfcli %{buildroot}/usr/sbin/pfcli

%post
echo "pls add crontab */5 * * * * /usr/sbin/pfcli restore >> /var/log/socat_manage.log 2>&1"

%preun
# No action needed before uninstall

%postun
# Clean up on complete removal
echo "Don't forget clean "
echo "     log file: /var/log/socat_manage.log"
echo "     data file: $HOME/.socat_mappings"

%files
%attr(0755,root,root) /usr/sbin/pfcli


%changelog
* Mon Oct 22 2025 cylonchau <cylonchau@outlook.com> - 0.0.1-1
- Initial release