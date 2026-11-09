Name:           wick
Version:        0.3.0
Release:        1%{?dist}
Summary:        Keeps a Linux laptop awake with the lid closed

License:        MIT
URL:            https://github.com/s1lvazxy/wick
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

BuildRequires:  python3-devel
BuildRequires:  python3-pip
BuildRequires:  python3-setuptools
BuildRequires:  python3-wheel
BuildRequires:  pyproject-rpm-macros
Requires:       systemd
Requires:       python3
Recommends:     python3-gobject
Recommends:     libayatana-appindicator-gtk3

%description
Wick keeps a Linux laptop awake with the lid closed, so coding agents, builds and
downloads finish while you walk away. It holds a systemd-logind inhibitor lock, needs
no root, and always gives the lock back: on a timer, at low battery, near critical
temperature, when agents finish, or if its own process dies.

%prep
%autosetup

%generate_buildrequires
%pyproject_buildrequires

%build
%pyproject_wheel

%install
%pyproject_install
%pyproject_save_files -L wick

%files -f %{pyproject_files}
%doc README.md
%{_bindir}/wick

%changelog
* Mon Nov 09 2026 s1lvazxy - 0.3.0-1
- Stop for heat sooner when the lid is closed, and show the heat in status, doctor and the panels

* Mon Nov 02 2026 s1lvazxy - 0.2.0-1
- First official Linux release, based on the port by gust330
