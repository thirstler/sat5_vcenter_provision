#!/usr/bin/perl -w

###############################################################################
#                                                                             #
# Date:        2014-11-06                                                     #
# Author:      Jason Russler                                                  #
# License:     None                                                           #
# Support:     This script is NOT supported by Red Hat. In the event that     #
#              this script stops performing for any reason, the you are       #
#              responsible for fixing it or discontinuing use.                #
#                                                                             #
# Description: This tool will create a new virtual machine (from a template)  #
#              and cobbler system profile, effectively "gluing" the Satellite #
#              and Vmware together to make provisioning a little easier.      #
#                                                                             #
###############################################################################
use strict;
use warnings;
use VMware::VIRuntime;
use IO::Handle qw();
use Getopt::Std;

##
# Set default values for Vmware API
# vCenter
$ENV{VI_URL} = "https://some.server.com/sdk";
# User name [username]@[domain]
#$ENV{VI_USERNAME} = '';
# Password if you want it
#$ENV{VI_PASSWORD} = '';

##
# Specify a default datacenter if you want (full text name), otherwise leave
# at 0.
my $default_datacenter = 0;

##
# Some extra output. Probably not useful.
my $debug=0;

##############################################################################
# Helper functions

##
# True if answer is yes.
sub answer_yes
{
    if($debug) { print("enter answer_yes()\n"); }
    my $answer = "";
    while(1) {
        STDOUT->flush();
        $answer = <STDIN>;
        $answer = lc($answer);
        if( substr($answer, 0, 1) eq "y" ) {
            return 1;
        }
        if( substr($answer, 0, 1) eq "n" ) {
            return 0;
        }
        print("?: ");
    }
}

##
# Just take input from STDIN. Takes two parameters
# 1) string - test to display for query
# 2) bool (1/0) - ask for input confirmation
sub getinput
{
    my $query = shift(@_);
    my $confirm = shift(@_);
    my $input;
    while(1) {
        print($query);
        STDOUT->flush();
        $input = <STDIN>;
        chomp($input);
        
        if($confirm) {
            print("you entered '$input', is that correct? [y/n]");
            if(answer_yes()) {last;}
        } else {last;}
    }
    return $input;
}

##
# Input validator for numeric input. Paramaters:
# 1) string - text to display in query
# 2) integer - maximum valid input value (inclusive minimum is always 1)
# 3) integer - if there's a default value, put it here
sub selectme
{
    my $query = shift(@_);
    my $valid_le = shift(@_);
    my $default = shift(@_);
    my $input;
    
    while(1) {
        print("${query}: ");
        STDOUT->flush();
        $input = <STDIN>;
        chomp($input);
        
        if( defined($default) && $input eq  "" ) { return $default; }
        
        if( $input =~ /^\d+$/ ) {
            if(scalar($input) < 1 || scalar($input) > $valid_le) {
                print("selection out of range!\n");
            } else {
                # Subtract one since lists are assumed to be array indexes
                return scalar($input)-1;
            }
        } else {
            print("please select options by number\n");
        }
    }
}

##
# Dumb check to see if it looks like Satellite is installed.
sub chk_sat
{
    ( -d "/var/satellite" ) && return 1;
    return 0;
}

##############################################################################
# vCenter related functions

##
# Log into vCenter
sub login
{
    if($debug) { print("enter login()\n"); }
    print("logging into vCenter...\n");
    STDOUT->flush();
    # read/validate options
    Opts::parse();
    Opts::validate();
    Util::connect();
    my $si = Vim::get_service_instance();
    print "\n".$si->content->about->fullName."\n";
}

##
# - "Your usual table, Mr. Christopher?"
# - "No, I would like a good one this time."
# - "I'm sorry, that is impossible."
# - "Part of the new creuly?"
# - "I'm afraid so."
#
# Get a host view based on VMware "fairness" factors. Needed for placement of
# new VMs. Parameters:
# 1) object, search base (probably a datacenter object)
sub get_a_good_host_view
{
    if($debug) { print("enter get_a_good_host_view()\n"); }
    my $return_view;
    my $from_view = shift(@_);
    my $hosts = Vim::find_entity_views(
            view_type => "HostSystem",
            begin_entity => $from_view,
            properties => ["summary.quickStats","summary.config", "datastore"]);
         
    my $fairness = 0;
    my $i = 0;
    my $c = 0;
    my @mem = [];
    my @cpu = [];
    foreach my $h (@{$hosts}) {
        
        if( defined($h->{'summary.quickStats'}->distributedMemoryFairness) && 
            defined($h->{'summary.quickStats'}->distributedCpuFairness)) {
            
            my $memfair = $h->{'summary.quickStats'}->distributedMemoryFairness;
            my $cpufair = $h->{'summary.quickStats'}->distributedCpuFairness;
            my $sysfair = $memfair + $cpufair;
            if($sysfair > $fairness) {
                $fairness = $sysfair;
                $c = $i;
            }
            $mem[$i] = $memfair/10000;
            $cpu[$i] = $cpufair/10000;
        }
        
        $i += 1;
    }
    
    print("\n");
    print("       hostname (\"fairness\" factors; higher means more avail resources)\n");
    print("------------------------------------------------------------------------\n");
    $i = 0;
    foreach my $h (@{$hosts}) {
        if( defined($cpu[$i]) && defined($mem[$i]) ) {
            if($c == $i) {
                print("  * ".(${i}+1).") ");
            } else {
                print("    ".(${i}+1).") ");
            }
            print $h->{'summary.config'}->{"name"}." (cpu:".$cpu[$i].", mem:".$mem[$i].")\n";
        }
        $i += 1;
    }
    print("\n");
    
    while(1) {
        
        my $selection = selectme(
            "select a host (".$hosts->[$c]->{'summary.config'}->{"name"}.")",
            $i, $c);
                            
        if($hosts->[$selection]) {
            print("use ".$hosts->[$selection]->{'summary.config'}->{"name"}."? [y/n]: ");
        } else {
            print("invalid selection\n");
            next;
        }
        
        if(answer_yes()) {
            return $hosts->[$selection];
        }
    }
}

##
# Get a list of datacenters available to this user on the bound vCenter.
# Return view of the selected datacenter. If a datacenter was specified at the
# command line, it will automatically return that datacenter (if it exists).
sub get_datacenter
{
    if($debug) { print("enter get_datacenter()\n"); }
    
    if($default_datacenter) {
        my $defdc =  Vim::find_entity_view(
                view_type => "Datacenter",
                filter => {"name" => $default_datacenter});
        if (! $defdc ) {
            print("bad datacenter name specified at the command line!\n");
            $default_datacenter = 0;
            return get_datacenter();
        } else {
            print("Using datacenter: ${default_datacenter}\n");
            return $defdc;
        }
    }
    
    my $answer = "";
    my $views = Vim::find_entity_views(
            view_type => "Datacenter",
            properties => ["name"]);
    print("\n");
    print("Select a datacenter:\n\n");
    my $sel = 0;
    my $i = 0;
    foreach my $n (@{$views}) {
        $sel+=1;
        print "  ".$sel.": ".$n->{"name"}."\n";
        $i += 1;
    }
    print("\n");
    
    while(1) {
        $answer = selectme("selection", $i);
        print("work in datacenter: '".$views->[$answer]->{"name"}."'? [y/n]: ");
        if( answer_yes() ) { return $views->[$answer]; }
    }
}

##
# Get a VM view by VM name. Parameters:
# 1) string, name of VM in vmware
# 2) object, Vmware object search base
sub get_vm_by_name
{
    if($debug) { print("enter get_vm_by_name()\n"); }
    my $vm_name = shift(@_);
    my $base_view = shift(@_);
    
    my $vm_view = Vim::find_entity_view(
        view_type => "VirtualMachine",
        begin_entity => $base_view,
        filter => {"name" => $vm_name});
        
    return $vm_view;
}

##
# List all VMs in the passed-in view that are in a powered-off state.
# Parameters:
# 1) object, Vmware object search base
sub get_powered_off_vms
{
    if($debug) { print("enter get_powered_off_vms()\n"); }
    my $ds_view = shift(@_);
    
    my $vm_views = Vim::find_entity_views(
            view_type => "VirtualMachine",
            begin_entity => $ds_view,
            properties => ["name"],
            filter => { "runtime.powerState" => "poweredOff" });
    return $vm_views;
}

##
# List all VMs in the passed-in view
# 1) object, Vmware object search base
sub get_all_vms
{
    if($debug) { print("enter get_all_vms()\n"); }
    my $ds_view = shift(@_);
    
    my $vm_views = Vim::find_entity_views(
            view_type => "VirtualMachine",
            begin_entity => $ds_view,
            properties => ["name"]);
    return $vm_views;
}

##
# Find the datastore with the most available space. Parameters:
# 1) object, Vmware object search base (probably a host object)
sub get_good_datastore
{
    if($debug) { print("enter get_good_datastore()\n"); }
    my $host_view = shift(@_);
    my $ds_mor_array = $host_view->datastore;
    my $datastores = Vim::get_views(mo_ref_array => $ds_mor_array);
    
    my @ds;
    my $i = my $sel = my $max = 0;
    foreach my $ds (@$datastores) {
        my $usage = $ds->summary->freeSpace/$ds->summary->capacity;
        push(@ds, {
            "ds_name" => $ds->summary->name,
            "capacity" => $ds->summary->capacity,
            "ds_free" => $ds->summary->freeSpace,
            "use" => $usage
        });
        if ( ($ds->summary->freeSpace > $max) && $ds->summary->accessible ) {
            $max = $ds->summary->freeSpace;
            $sel = $i;
        }
        $i += 1;
    }
    
    print("\n");
    $i = 0;
    foreach my $ds (@ds) {
        my $mb_cap = sprintf("%.2f", ($ds->{"capacity"}/1000000000));
        my $mb_free = sprintf("%.2f", ($ds->{"ds_free"}/1000000000));
        if($i == $sel) {
            print "  * ";
        } else {
            print "    ";
        }
        print( ($i+1).") ".$ds->{"ds_name"}." ${mb_free}GB free (out of ${mb_cap}GB)\n");
        $i+=1;
    }
    
    print("\n");
    while(1) {
        
        my $selection = selectme("enter selection (".$datastores->[$sel]->summary->name.")",
                                 $i, $sel);
        
        if($datastores->[$selection]) {
            print("use ".$datastores->[$selection]->summary->name."? ");
            if(answer_yes()) {
                return $datastores->[$selection];
            }
        }
    }
}

##
# Entry-point for creating a new VM based on a template. Takes no arguments
# and returns nothing.
sub vm_from_template
{
    if($debug) { print("enter vm_from_template()\n"); }
    my $sel = 0;
    my $answer = "";
    my $view = 0;
    my $vm_view = 0;
    
    print("finding useable templates...");
    STDOUT->flush();
    $view = get_datacenter();
    
    print("finding powered-off VMs to clone from...");
    STDOUT->flush();
    
    my $vm_views = get_powered_off_vms($view);
    
    print("\nselect a VM:\n\n");
    
    foreach my $n (@{$vm_views}) {
        $sel += 1;
        print "  ".$sel.": ".$n->{"name"}."\n";
    }
    while(1) {
        print("\nselection: ");
        STDOUT->flush();
        $answer = <STDIN>;
        chomp($answer);
        $answer = scalar($answer);
        if($answer > 0 && $answer < $sel+1) {
            print("clone new VM from ".$vm_views->[$answer-1]->{"name"}."? [y/n]: ");
            if(answer_yes()) {
                $vm_view = $vm_views->[$answer-1];
                last;
            } else {
                next;
            }
        }
    }
    print("\n");
    
    print("new VM name: ");
    STDOUT->flush();
    
    my $new_vm_name = "";
    
    while(1) {
        $new_vm_name = <STDIN>;
        chomp($new_vm_name);
        print("create new VM: '$new_vm_name'? ");
        if(answer_yes()) {
            last;
        }
        print "? ";
        STDOUT->flush();
    }
    
    my $host_view = get_a_good_host_view($view);
    my $comp_res_view = Vim::get_view(mo_ref => $host_view->parent);
    
    my $relocate_spec = VirtualMachineRelocateSpec->new(
            host => $host_view,
            folder => $vm_view->parent);
            
    my $clone_spec = VirtualMachineCloneSpec->new(
            powerOn => 0,
            template => 0,
            location => $relocate_spec);
            
    $vm_view->CloneVM(
            folder => $vm_view->parent,
            name => $new_vm_name,
            spec => $clone_spec);
}

##
# Lists virtual machines in the passed-in view and returns a vm view
# Paremeters:
# 1) object, search base vmware object
sub find_vm
{
    if($debug) { print("enter find_vm()\n"); }
    my $dc_view = shift(@_);
    
    if( ! $dc_view) {
        print("let's find that VM, what datacenter?\n");
        $dc_view = get_datacenter();
    }
    print("list (a)ll VMs or only (p)owered-off VMs [a/P]: ");
    STDOUT->flush();
    my $vms;
    while(1) {
        my $selection = <STDIN>;
        chomp($selection);
        $selection = lc($selection);
        if($selection eq "") {
            $selection = "p";
        }
        if($selection eq "p") {
            $vms = get_powered_off_vms($dc_view);
            last;
        }
        if($selection eq "a") {
            $vms = get_all_vms($dc_view);
            last;
        }
        print("?: ");
        STDOUT->flush();
    }
    print("\n");
    
    my $i = 1;
    foreach my $vm (@{$vms}) {
        print("  ${i}: ",$vm->{"name"}."\n");
        $i+=1;
    }
    print("\n");
    my $selection = "";
    while(1) {
        
        $selection = selectme("selection", $i-1);
        $selection = $selection-1;
        
        print("use '".$vms->[$selection]->{"name"}."'? [y/n]: ");
        STDOUT->flush();
        
        if(answer_yes()) {
            last;
        }
    }
    my $vm = get_vm_by_name($vms->[$selection]->{"name"}, $dc_view);
    
    return $vm;
}

##
# Dump a list of kickstart profiles (via cobbler) to choose from.
# WARNING!!!!
# This does not use a proper API to talk to cobbler, it just runs commands 
# and scrapes the output. Sucky, but I can't do anything about it. Cobbler
# output is very unlikely to change format so I'm hoping this will not be a
# problem. Cobbler does provide an API but it's off by default in Satellite
# for security reasons: It's not organization aware. If enabled, the cobbler
# API would allow a user to alter any organization's cobbler objects, not just
# their own.
sub get_profiles
{
    if($debug) { print("enter get_profiles()\n"); }
    my $cobbler_cmd = `which cobbler`;
    chomp($cobbler_cmd);
    if ( ! -f $cobbler_cmd ) {
        print("no cobbler on this system. Are you sure you're in the right place?");
        die("no cobbler");
    }
    my $cmd = "${cobbler_cmd} profile list";
    my $cob_profiles = `$cmd`;
    my @profiles = [];
    foreach my $p (split('\n', $cob_profiles)) {
        $p =~ s/^\s+|\s+$//;
        push(@profiles, $p);
    }
    return @profiles;
}

##
# Check to see if a system definition exists in cobbler. Should keep you from
# doing a bunch of work only to have cobbler pooch-out at the end.
sub sysdef_name_exists
{
    if($debug) { print("enter sysdef_name_exists()\n"); }
    my $sysdefname = shift(@_);
    chomp($sysdefname);
    my $cmd = "cobbler system list | grep ' $sysdefname\$'";
    my $output = `$cmd`;
    if($output ne "") {
        print("system name '$sysdefname' already appears in cobbler\n");
        print("if you would like to reprovision this system, exit this script and:\n\n");
        print("  # cobbler system edit --name=$sysdefname --netboot-enable=1\n\n");
        print("if you would like to remove the old profile, exit this script and:\n\n");
        print("  # cobbler system remove --name=$sysdefname\n\n");
        print("and try again.\n");
        return 1;
    }
    return 0;
}

##
# Create a cobbler profile for the passed-in virtual machine and initial 
# config hashtable. Parameters:
# 1) object, virtual machine view
# 2) hashtable, configuration options gathered in init_collect()
sub cobbler_setup
{
    if($debug) { print("enter cobbler_setup()\n"); }
    my $target_vm = shift(@_);
    my $init_config = shift(@_);
    
    print("\n\n\n##\n# COBBLER SETUP\n");
    
    my @profiles = get_profiles();
    print("\nSelect a kickstart profile from which to base this install:\n\n");
    my $i=0;
    # Starts with 1 because element 0 is an array
    for($i=1; $i < scalar(@profiles); $i+=1) {
        print "  ${i}: ".$profiles[$i]."\n";
    }
    print("\n");
    
    my $profile;
    while(1) {
        
        my $selection = selectme("selection profile", ($i-1));
        $selection+=1; # This is off due to shifted array. There, fixed.
        print("use '".$profiles[$selection]."'? [y/n]: ");
        if(answer_yes()) {
            $profile = $profiles[$selection];
            last;
        }
        
    }
    my $hostname;
    if(! $init_config->{"hostname"} ) {
        $hostname = getinput("hostname: ", 1);
    } else {
        $hostname = $init_config->{"hostname"};
    }
    
    my $sysdefname;
    if(! $init_config->{"cobbler_name"} ) {
        $sysdefname = getinput("system def name (${hostname}): ", 1);
    } else {
        $sysdefname = $init_config->{"cobbler_name"};
    }
    
    if( sysdef_name_exists($sysdefname) ) {
        while(1) {
            print("name already in use! (s)tart cobbler setup over or (e)xit? [s/e]: ");
            STDOUT->flush();
            my $selection = <STDIN>;
            chomp($selection);
            if($selection eq "s") {
                return cobbler_setup($target_vm, $init_config);
            }
            if($selection eq "e") {
                die("user exit");
            }
        }
    }
    
    my @network = define_network($target_vm);
    
    my @cob_cmds;
    my $cob_cmd = "cobbler system add --name=".$sysdefname." ".
            "--hostname=".$hostname." ".
            "--profile=".$profile." ";
    if($network[0]{"proto"} eq "dhcp") {
        $cob_cmd .= "--interface=eth0 --static=0";
    } else {
        $cob_cmd .= "--interface=eth0 ".
            "--static=1 ".
            "--mac-address=".$network[0]{"mac"}." ".
            "--ip-address=".$network[0]{"ip"}." ".
            "--name-servers='".join(" ", @{$network[0]{"dns"}})."' ".
            "--subnet=".$network[0]{"netmask"}." ".
            "--gateway=".$network[0]{"gateway"};
    }
    
    push(@cob_cmds, $cob_cmd);
    
    $cob_cmd = 0;
    if(scalar(@network) > 1) {
        my $p_count = 0;
        my $k_count = 0;
        for(my $i=0; $i < scalar(@network); $i += 1) {
            if($network[$i]{"ks"} == 1) {$k_count += 1;}
            if($network[$i]{"pxe"} == 1) {$p_count += 1;}
        }
        if($k_count != 1 or $p_count !=1) {
            print("there needs to be ONE PXE device and ONE kickstart device defined!");
            print("restarting network setup...");
            return cobbler_setup($target_vm);
        }
    }
    
    for(my $i=1; $i < scalar(@network); $i += 1) {
        $cob_cmd = "cobbler system edit --name=".$sysdefname." ".
            "--interface=eth${i} ";
        if($network[$i]{"proto"} eq "dhcp") {
            $cob_cmd .= "--static=0 --mac-address=".$network[$i]{"mac"};
                
        } else {
            $cob_cmd .= $cob_cmd .= "--interface=eth${i} --static=1".
                "--mac-address=".$network[$i]{"mac"}." ".
                "--ip-address=".$network[$i]{"ip"}." ".
                "--name-servers='".join(" ", @{$network[$i]->{"dns"}})."' ".
                "--subnet=".$network[$i]{"netmask"}." ".
                "--gateway=".$network[$i]{"gateway"};
        }
        if($network[$i]{"pxe"} == 1) {
            
            # Find the kick-start device
            my $ks_index = 0;
            for(my $z=0; $z < scalar(@network); $z += 1) {
                if($network[$z]{"ks"} == 1) {
                    $ks_index = $z;
                    last;
                }
            }
            
            $cob_cmd .= " --kopts=\"ip=".$network[$ks_index]{"ip"}." ".
                "netmask=".$network[$ks_index]{"netmask"}." ".
                "gateway=".$network[$ks_index]{"gateway"}." ".
                "dns=".join(",", @{$network[$ks_index]->{"dns"}})." ".
                "ksdevice=eth${ks_index}\"";
        }
        push(@cob_cmds, $cob_cmd);
    }
    
    print("creating cobbler system definition...");
    STDOUT->flush();
    my $ouput;
    foreach my $cmd (@cob_cmds) {
        #print($cmd."\n");
        $ouput = `$cmd`;
        if($ouput) { print($ouput."\n"); }
    }
    $ouput = `cobbler sync 2>&1 1>/dev/null`;
    if($ouput) { print($ouput."\n"); }
    print("done\n");
    
}

##
# Just take an IP address from STDIN. Does some checking to make sure it's
# a valid IP address. Just joking! As long as it's a bunch of numbers separated
# by three dots we're cool! Right? Parameters:
# 1) string, text to show when asking for input
sub input_ip_addr
{
    if($debug) { print("enter input_ip_addr()\n"); }
    my $type = shift(@_);
    my $addr;
    OUTER: while(1) {
        print("${type} address: ");
        STDOUT->flush();
        $addr = <STDIN>;
        chomp($addr);
        if($addr eq "") { return 0; }
        if( $addr !~ m/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
            print("invalid address\n");
            next;
        }
        my @octets = split(/\./, $addr);
        INNER: foreach my $octet (@octets) {
            if($octet > 255 or $octet < 0) {
                print("invalid address!\n");
                next OUTER;
            }
        }
        last;
    }
    return $addr;
}

##
# Take configuration information for a network interface, Return a neatly
# packaged hastable with the results.
sub manual_iface_input
{
    if($debug) { print("enter manual_iface_input()\n"); }
    my $ip_addr = input_ip_addr("ip");
    
    my $cmd = "cobbler system find --ip-address=$ip_addr";
    my $output = `$cmd`;
    chomp($output);
    if($output) {
        print("A system with this IP address already exists: ${output}\n");
        print("try again? [y/n]");
        if(answer_yes()) { return manual_iface_input(); }
        else {
            print("(you may want to clean up the VM you just cloned)\n");
            die("bad IP address");
        }
    }
    
    my $netmask_addr = input_ip_addr("netmask");
    my $gateway_addr = input_ip_addr("gateway");
    
    print("enter DNS addresses one-by-one, 'return' to finish:\n");
    my @dns;
    my $i = 0;
    while(1) {
        my $addr = input_ip_addr("dns(${i})");
        $i += 1;
        if($addr) { push(@dns, $addr); }
        else { last; }
    }
    
    return {"proto" => "static",
        "ip" => $ip_addr,
        "netmask" => $netmask_addr,
        "gateway" => $gateway_addr,
        "dns" => \@dns };
}

##
# Define network for a virtual machine. Parameters:
# 1) object, virtual machine view
sub define_network
{
    if($debug) { print("enter define_network()\n"); }
    my $target_vm  = shift(@_);
    my @network_devices;
    foreach my $dev (@{$target_vm->{"config"}->{"hardware"}->{"device"}}) {
        if( $dev->{"macAddress"} ) {
            push(@network_devices, $dev);
        }
    }
    
    print("\n\n\nEstablishing network configuration for new or reprovisioned VM:\n\n");
    my @network;
    my $pxe_selected = 0;
    my $ks_selected = 0;
    for(my $i = 0; $i < scalar(@network_devices); $i += 1) {
        print("setting up device on network '".
                $network_devices[$i]->{"backing"}->{"deviceName"}."' (".
                $network_devices[$i]->{"macAddress"}.")\n");
        print("[m]anual address setup or [d]hcp? [m/d]: ");
        STDOUT->flush();
        while(1) {
            my $selection = <STDIN>;
            $selection = lc($selection);
            if( substr($selection, 0, 1) eq "m" ) {
                $network[$i] = manual_iface_input();
                $network[$i]{"mac"} = $network_devices[$i]->{"macAddress"};
                last;
            }
            if( substr($selection, 0, 1) eq "d" ) {
                $network[$i] = {"proto" => "dhcp"};
                $network[$i]{"mac"} = $network_devices[$i]->{"macAddress"};
                last;
            }
            print("? [m/d]: ");
        }
        
        $network[$i]{"pxe"} = 0;
        $network[$i]{"ks"} = 0;
        if(scalar(@network_devices) > 1) {
            
            if(!$pxe_selected and $network[$i]{"proto"} eq "dhcp" ) {
                print("is this the PXE inferface? [y/n]: ");
                if(answer_yes()) {
                    $network[$i]{"pxe"} = 1;
                    $pxe_selected = 1;
                } else {
                    $network[$i]{"pxe"} = 0;
                }
            }
            
            if(!$ks_selected) {
                print("is this the kickstart/install inferface? [y/n]: ");
                if(answer_yes()) {
                    $network[$i]{"ks"} = 1;
                    $ks_selected = 1;
                } else {
                    $network[$i]{"ks"} = 0;
                }
            }
        } else {
            $network[$i]{"pxe"} = 1;
            $network[$i]{"ks"} = 1;
        }
        
    }
    return @network;
}

##
# Go through the steps of cloning a VM in the specified datacenter.
# Parameters:
# 1) hashtable, list of options gathered in init_collect()
sub clone_vm_from_template
{
    if($debug) { print("enter clone_vm_from_template()\n"); }
    
    my $init_config = shift(@_);
    my $ds = $init_config->{"datacenter"};
    
    print("\n\n\n##\n# VMWARE SETUP\n");
    
    print("\nOn which host do we want to (initially) place this sytem?\n");
    print("(return to use recommendation; recommendation method is not sophisticated so
please review)\n");
    my $hv = get_a_good_host_view($ds);
    
    print("\n\n\nWhich data store do you want to use?\n");
    print("(return to use recommendation; recommendation method is not sophisticated so
please review)\n");
    my $storg = get_good_datastore($hv);
    
    print("\n\n\nLet's find the VM template you'd like to clone from.\n");
    my $cloneme = find_vm($ds);
    
    my $relocate_spec = VirtualMachineRelocateSpec->new(
            datastore => $storg,
            host => $hv,
            pool => $cloneme->resourcePool);
            
    my $clone_spec = VirtualMachineCloneSpec->new(
            powerOn => 0,
            template => 0,
            location => $relocate_spec);
    
    my $new_vm_name = "clone of ".$cloneme->config->name;
    
    if( ! $init_config->{"vm_name"} ) {
        $new_vm_name = getinput("name for new VM: ", 1);
    } else {
        $new_vm_name = $init_config->{"vm_name"};
    }
    
    print("cloning...");
    STDOUT->flush();
    # Clone source vm, pass vm host, folder and new vm name
    $cloneme->CloneVM(
            folder => $cloneme->parent,
            name => $new_vm_name,
            spec => $clone_spec);
    print("done.\n");
    
    return get_vm_by_name($new_vm_name, $ds);
}

##
# Pretty dumb. Turns on the passed-in VM. 
# Parameters:
# 1) object, VM view
sub poweron_vm
{
    if($debug) { print("enter poweron_vm()\n"); }
    my $vm = shift(@_);
    print("\n\n\nDo you want to power-on the target VM (start installation)? ");
    STDOUT->flush();
    if(answer_yes()) {
        $vm->PowerOnVM();
        return 1;
    }
    return 0;
}

##
# Collect some initial settings so we can check the Vmware infrastructure and
# cobbler database for anything that might conflict later. Takes no arguments
# and returns a neat little hashtable of everything you said here. So don't
# lie.
sub init_collect
{
    my $vm_name = 0;
    my $cobbler_name = 0;
    
    print("\n\n\nWhere are we provisioning this new system?\n(in which datacenter is this Satellite?)\n");
    my $datacenter = get_datacenter();
    
    print("\n\n\nWhat will be the host name of this new system?\n");
    my $sysname = getinput("name: ", 0);
    
    print("Should this be the cobbler system definition name and VM name as well? [y/n]: ");
    if(answer_yes()) {
        $vm_name  = $sysname;
        $cobbler_name = $sysname;
    } else {
        $vm_name = getinput("virtual machine name: ", 0);
        $cobbler_name = getinput("cobbler system name: ", 0);
    }
    
    if(get_vm_by_name($vm_name, $datacenter)) {
        print("WARNING! A VM with this name already exists in this datacenter.\n");
        die("duplicate VM name");
    }
    
    if(sysdef_name_exists($cobbler_name)) {
        print("WARNING! A system with this name already exists in cobbler.\n");
        die("duplicate cobbler name");
    }
    
    return({
        "datacenter" => $datacenter,
        "hostname" => $vm_name,
        "cobbler_name" => $cobbler_name,
        "vm_name" => $vm_name});
}

##############################################################################
# MAIN

my $help = "

==============================================================================
Hi! This script will guide you through the process of creating a _new_ system
for provisioning via cobbler (Satellite 5) and Vmware. It will:

 1 - Create a new VM in Vmware from the selected template.
 2 - Create a cobbler system definition profile that will provision the new
     virtual machine.
 3 - Kick-off a provision of the new system.
 
In order for this thing to work, you:

 1 - must be root on the Satellite server that will be servicing the
     provision - yucky, so much or organizations.
 2 - must not input a duplicate virtual machine name
 3 - must not input a duplicate cobbler system definition name
 4 - must not input network information (hostname, IP address) already used in
     an existing cobbler system definition.
     
This tool tries to check for some of this stuff but you may want to be sure as
well. If any of these rules are violated, this tool will bust.
  
See: \"cobbler --help\" for information about directly using the Satellite's
cobbler backend. This will tell you how to edit existing definitions, mark
definitions for re-install, remove definitions and other operations related
to provisioning.

See also: 'pod2text ${0} |less'

Enjoy!
==============================================================================

Usage: ".$0." [options]

Options:
  -h           this help message
  -s           vCenter server for log on
  -u           user ([username]@[domain])
  -p           password
  -c           datacenter to operate on

example:

  ${0} -s https://vcenter.example.com/sdk -u drteeth\@electricmayhem

";

my %options=();
getopts("hs:u:p:c:", \%options);

if (defined $options{h}) {
    print $help;
    exit(0);
}
if (defined $options{s}) { $ENV{VI_URL} = $options{s}; }
if (defined $options{u}) { $ENV{VI_USERNAME} = $options{u}; }
if (defined $options{p}) { $ENV{VI_PASSWORD} = $options{p}; }
if (defined $options{c}) { $default_datacenter = $options{c}; }

if(scalar(%options) eq 0) {
    print("You specified no options (hint: \"-h\" or 'pod2text ${0} |less')\n");
}

##
# Some stupid sanity checks
if( ! chk_sat() ) {
    print("It doesn't look like you're on a Satellite. No go.\n");
    exit(1);
}
my $mememe = `whoami`;
chomp($mememe);
if($mememe ne "root") {
    print("You're not root. No.\n");
    exit(1);
}

##
# Ok, let's go
login();

# Get inital values for sanity checking
my $init_config = init_collect();

# Clone VM and return new VM object so we can taylor a cobbler config for it
my $target_vm = clone_vm_from_template($init_config);

# Create cobbler config for provided VM topology
cobbler_setup($target_vm, $init_config);

# Smoke if you got 'em
poweron_vm($target_vm) && print("\nNew system should be installing right now. Go check.\n");

exit(0);

__END__

=head1 NAME

new_vm - Provisions a new VM with OS via Red Hat Satellite 5 (Spacewalk)
         
=head1 SYNOPSIS

new_vm [options]
    
=head1 DESCRIPTION

This script will provision a new VM in a Vmware infrastructure serviced by a
Red Hat Satellite with PXE boot services enabled and configured. It will
prompt the caller for various parameters: data center to operate on, name of
new system, template to provision from, kickstart profile for new system and
"last mile" network configuration information. It uses the Vmware Perl API
distributed with the vSphere CLI - so that will need to be installed before
this script will do anything. Notably, it does not use Cobbler's XMLRPC API
since it is disabled on Red Hat Satellite for security in multi-org
environments. Instead, it uses subshells for cobbler commands and scrapes the
output. This means root is required to use this script on a default Satellite
install.

=head1 OPTIONS

=over 4

=item B<-h>

General help

=item B<-s>

vCenter to use. Usually comes in the format: "https://server.name.here/api". A
default can be configured at the beginning of this script. Otherwise this is
a required option.

=item B<-u>

User to connect to the vCenter with. Use username@domain format myuser@mycorp.
Script will prompt if not specified.

=item B<-p>

Password for the user. No Kerberos here unfortunately (unless the vSphere CLI
supports it). Script will prompt if not specified.

=item B<-c>

Full name of the datacenter you want to use. This script will prompt you with
a list of available datacenters if not specified here.

=back

=head1 EXAMPLES

Connect to vCenter with user drteeth in AD domain electricmayhem.com, note the
use of the "shorthand" domain name:

    new_vm -s https://vcenter.example.com/sdk -u drteeth@electricmayhem

Connect using the configured default vCenter specifying "Dr Strangepork Lab"
as the target data center:

    new_vm -c "Dr Strangepork Lab"
    
