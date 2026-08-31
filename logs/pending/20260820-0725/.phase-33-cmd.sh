#!/bin/sh
echo xhci-hcd.2.auto | sudo tee /sys/bus/platform/drivers/xhci-hcd/unbind; cd sleep_test/scripts && sudo ./02-suspend-cycle.sh -d 60 -w; rc=$?; echo xhci-hcd.2.auto | sudo tee /sys/bus/platform/drivers/xhci-hcd/bind; exit $rc
