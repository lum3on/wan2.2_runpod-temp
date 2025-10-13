#!/usr/bin/env bash
# JupyterLab Permissions Diagnostic Script
# Run this inside the JupyterLab terminal to diagnose write permission issues

echo "=========================================================================="
echo "🔍 JUPYTERLAB PERMISSIONS DIAGNOSTIC"
echo "=========================================================================="
echo ""

echo "📋 Step 1: CANARY TEST - Can we write to /comfyui at all?"
echo "-------------------------------------------------------------------"
echo "Attempting to create a test file..."
if touch /comfyui/write_test.txt 2>/dev/null; then
    echo "✅ SUCCESS: Basic write test passed!"
    echo "   File created: /comfyui/write_test.txt"
    ls -l /comfyui/write_test.txt
    rm -f /comfyui/write_test.txt
    echo ""
    echo "⚠️  CONCLUSION: Filesystem is writable, but JupyterLab cannot write."
    echo "   This is a JupyterLab configuration issue, not a filesystem issue."
else
    echo "❌ FAILED: Cannot write to /comfyui"
    echo "   Error: Read-only file system or permission denied"
    echo ""
    echo "🎯 CONCLUSION: The problem is at the filesystem/mount level."
    echo "   Proceeding with mount diagnostics..."
fi
echo ""

echo "📋 Step 2: CHECK MOUNT CONFIGURATION"
echo "-------------------------------------------------------------------"
echo "Checking how /comfyui is mounted..."
echo ""
mount | grep comfyui
if [ $? -ne 0 ]; then
    echo "⚠️  /comfyui is not a separate mount point"
    echo "   Checking parent filesystem..."
    mount | grep " / "
fi
echo ""

echo "📋 Step 3: FILESYSTEM TYPE AND OPTIONS"
echo "-------------------------------------------------------------------"
echo "Getting detailed filesystem information..."
echo ""
if command -v findmnt &> /dev/null; then
    findmnt -n -o SOURCE,FSTYPE,OPTIONS /comfyui 2>/dev/null || findmnt -n -o SOURCE,FSTYPE,OPTIONS /
else
    df -hT /comfyui
fi
echo ""

echo "📋 Step 4: DIRECTORY PERMISSIONS"
echo "-------------------------------------------------------------------"
echo "Current permissions on /comfyui:"
ls -ld /comfyui
echo ""
echo "Permissions on parent directory:"
ls -ld /
echo ""

echo "📋 Step 5: CURRENT USER AND PROCESS INFO"
echo "-------------------------------------------------------------------"
echo "Current user: $(whoami)"
echo "User ID: $(id)"
echo ""
echo "JupyterLab process:"
ps aux | grep jupyter | grep -v grep
echo ""

echo "📋 Step 6: SELINUX/APPARMOR STATUS"
echo "-------------------------------------------------------------------"
if command -v getenforce &> /dev/null; then
    echo "SELinux status: $(getenforce)"
else
    echo "SELinux: Not installed"
fi
echo ""
if command -v aa-status &> /dev/null; then
    echo "AppArmor status:"
    aa-status 2>/dev/null || echo "AppArmor: Not active or no permission to check"
else
    echo "AppArmor: Not installed"
fi
echo ""

echo "📋 Step 7: DISK SPACE"
echo "-------------------------------------------------------------------"
df -h /comfyui
echo ""

echo "=========================================================================="
echo "🎯 DIAGNOSTIC SUMMARY"
echo "=========================================================================="
echo ""
echo "Please share this output with support to diagnose the issue."
echo ""
echo "Common issues and solutions:"
echo ""
echo "1. If 'Read-only file system' error in Step 1:"
echo "   → The volume is mounted as read-only"
echo "   → FIX: Check RunPod volume settings, ensure NOT read-only"
echo "   → OR: Work in /workspace instead (RunPod's writable area)"
echo ""
echo "2. If mount shows '(ro)' in Step 2:"
echo "   → Volume is explicitly mounted read-only"
echo "   → FIX: Modify RunPod template to mount as read-write"
echo ""
echo "3. If Step 1 succeeds but JupyterLab still fails:"
echo "   → JupyterLab configuration issue"
echo "   → FIX: Check JupyterLab root_dir and working directory"
echo ""
echo "4. If disk space is 100% in Step 7:"
echo "   → No space left on device"
echo "   → FIX: Clean up files or increase disk allocation"
echo ""
echo "=========================================================================="

