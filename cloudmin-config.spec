Name:           cloudmin-config
Version:        1.0.0
Release:        1
Summary:        Collection of plugins to initialize the configuration of services that Cloudmin manages, and a command line tool called config-system to run them
License:        GPL+
Group:          Development/Libraries
URL:            https://github.com/virtualmin/Cloudmin-Config/
Source0:        Cloudmin-Config-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
BuildRequires:  perl >= 0:5.016
BuildRequires:  perl(ExtUtils::MakeMaker)
BuildRequires:  perl(File::Spec)
BuildRequires:  perl(Log::Log4perl)
BuildRequires:  perl(Test::More)
BuildRequires:	perl(Module::Load)
Requires:	      webmin
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

#%check
#make test

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%doc dist.ini LICENSE META.json README
%{perl_vendorlib}/*
%{_mandir}/man1/*
%{_mandir}/man3/*
%{_bindir}/*
/usr/libexec/webmin/server-manager/config-system.pl

%changelog
* Sat Feb 04 2023 Joe Cooper <joe@virtualmin.com> 1.0.0
- Initial packaging
