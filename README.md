# sat5_vcenter_provision

What does this do?

This short script should be able to provision virtual machines in an ESX 5.x
environment in tandem with a Red Hat Satellite 5.x management infrastructure.
It relies on the "VMware::VIRuntime" perl modules available from VMWare for
communication with your vCenter. Communication with the Satellite is done via
ugly shell calls which means this script needs to be run on the Satellite to
which the target (new) system is to be registered. Furthermore, you must be
root. Using the cobbler API is out of the questions since it requires opening
up an API that does not recognize the Satellite authorization system -
specifically, cobbler does not know about Satellite organizations.

So, in short:

 - Make sure you have a user in your vCenter environment that has permissions
   to create virtual machines.
 - Make sure you have a virtual machine template (with an empty disk) from 
   which to clone a new VM.
 - Make sure you have a working PXE provisioning system with your Satellite.
 - Configure this script with your vCenter name/address (you can also configure
   credentials if you want).
 - Run the script as root on your Satellite.

If all goes well, you'll get guided through a series of questions regarding
which data center, cluster and storage you want the system to come up on. If
you're not me and you have issues with this script you can contact me directly:

jason.russler@gmail.com


