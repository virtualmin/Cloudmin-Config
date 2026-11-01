Name:           cloudmin-config
Version:        10.0.0
Release:        1
Summary:        Collection of plugins to initialize the configuration of services that Cloudmin manages, and a command line tool called config-system to run them
License:        GPLv3
Vendor:         Cloudmin, LLC
Packager:       Ilia Ross <ilia@webmin.dev>
Group:          Development/Libraries
URL:            https://github.com/virtualmin/Cloudmin-Config/
Source0:        Cloudmin-Config-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
BuildRequires:  perl >= 0:5.026
BuildRequires:  perl(ExtUtils::MakeMaker)
BuildRequires:  perl(File::Spec)
BuildRequires:  perl(Log::Log4perl)
BuildRequires:  perl(Test::More)
BuildRequires:  perl(Module::Load)
BuildRequires:  perl(XML::LibXML)
BuildRequires:  perl(Sys::Virt)
Requires:       webmin >= 2.670
Requires:       webmin-server-manager
Requires:       perl(Sys::Virt)
Requires:       perl(XML::LibXML)
Requires:       perl(JSON::PP)
Requires:       perl(Log::Log4perl)
Requires:       perl(Term::ANSIColor)
Requires:	      perl(Module::Load)

%description
This is a mini-framework for configuring elements of a Cloudmin system.
It uses Webmin as a library to abstract common configuration tasks,
provides a friendly status indicator, and makes it easy to pick and choose
the kind of configuration you want (should you choose to go that route).

%prep
%setup -q -n Cloudmin-Config-%{version}

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor
make %{?_smp_mflags}

%install
rm -rf $RPM_BUILD_ROOT

make pure_install PERL_INSTALL_ROOT=$RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT/usr/libexec/webmin/server-manager
# link cloudmin-config-system into Cloudmin dir
ln -s /usr/bin/cloudmin-config-system \
  $RPM_BUILD_ROOT/usr/libexec/webmin/server-manager/config-system.pl

find $RPM_BUILD_ROOT -type f -name .packlist -exec rm -f {} \;
find $RPM_BUILD_ROOT -depth -type d -exec rmdir {} 2>/dev/null \;

%{_fixperms} $RPM_BUILD_ROOT/*

# Unit tests model system actions; live service tests run separately.
%check
make test

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%doc LICENSE README.pod
%{perl_vendorlib}/*
%{_mandir}/man1/*
%{_mandir}/man3/*
%{_bindir}/*
/usr/libexec/webmin/server-manager/config-system.pl

%changelog
* Sun Nov 01 2026 Ilia Ross <ilia@webmin.dev> 10.0.0-1
- Add Cloudmin 10 support with native libvirt integration
