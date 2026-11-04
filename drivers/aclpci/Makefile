MODULENAME ?= altr_aclpci_cvp_drv

# Final module
obj-m := $(MODULENAME).o

# List of object files to compile for the final module.
$(MODULENAME)-y :=

#Enable debug
ccflags-$(CONFIG_DRIVER) += -DDEBUG

# List of object files to compile for the final module.
$(MODULENAME)-y := aclpci_queue.o aclpci.o aclpci_fileio.o aclpci_dma.o aclpci_pr.o aclpci_cmd.o \
                  aclpci_user_dma.o aclpci_dma_batch.o aclpci_dma_request.o aclpci_round_fence.o aclpci_supervisor_command.o aclpci_context_provision.o aclpci_identity.o aclpci_startup.o aclpci_startup_closed.o aclpci_upstream_closure.o
