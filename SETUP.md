# Claude Code Statusline Setup Instructions

This guide provides step-by-step instructions to install and configure the intelligent statusline for Claude Code.

## Prerequisites

- Claude Code installed and working
- `bash` shell (standard on macOS/Linux)
- `jq` command-line JSON processor (recommended)

## Step 1: Install jq (if not already installed)

### macOS (using Homebrew)
```bash
brew install jq
```

### macOS (using MacPorts)
```bash
sudo port install jq
```

### Linux (Ubuntu/Debian)
```bash
sudo apt-get install jq
```

### Linux (CentOS/RHEL)
```bash
sudo yum install jq
```

### Verify jq installation
```bash
jq --version
```

## Step 2: Copy Files to Claude Code Directory

1. **Navigate to your Claude Code configuration directory:**
   ```bash
   cd ~/.claude
   ```

2. **Copy the statusline script:**
   ```bash
   cp /path/to/your/claude-code-status-line/statusline.sh ~/.claude/statusline.sh
   ```

3. **Make the script executable:**
   ```bash
   chmod +x ~/.claude/statusline.sh
   ```

4. **Test the script works:**
   ```bash
   echo '{}' | ~/.claude/statusline.sh
   ```
   You should see a statusline output with basic information.

## Step 3: Configure Claude Code Settings

### Option A: If NO settings.json exists

1. **Create a new settings.json file:**
   ```bash
   cd ~/.claude
   cp /path/to/your/claude-code-status-line/settings.json ~/.claude/settings.json
   ```

2. **Verify the file was created:**
   ```bash
   cat ~/.claude/settings.json
   ```

### Option B: If settings.json already exists

1. **Back up your existing settings:**
   ```bash
   cp ~/.claude/settings.json ~/.claude/settings.json.backup
   ```

2. **Check your current settings structure:**
   ```bash
   cat ~/.claude/settings.json
   ```

3. **Add the statusline configuration to your existing settings.json:**

   Open your settings file in your preferred editor:
   ```bash
   nano ~/.claude/settings.json
   # or
   vim ~/.claude/settings.json
   # or
   code ~/.claude/settings.json
   ```

4. **Add the statusLine section to your JSON:**

   If your settings.json is empty `{}` or minimal, replace the entire content with:
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "padding": 0,
       "logFile": "~/.claude/statusline.log",
       "description": "Intelligent resource monitoring statusline with real-time API limits, token usage, and recommendations"
     }
   }
   ```

   If your settings.json already has other configurations, add the statusLine section. For example:
   ```json
   {
     "existingOption": "value",
     "anotherOption": true,
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline.sh",
       "padding": 0,
       "logFile": "~/.claude/statusline.log",
       "description": "Intelligent resource monitoring statusline with real-time API limits, token usage, and recommendations"
     }
   }
   ```

5. **Validate your JSON syntax:**
   ```bash
   jq . ~/.claude/settings.json
   ```
   This should output your formatted JSON. If there's an error, fix the syntax.

## Step 4: Restart Claude Code

1. **Exit Claude Code completely** (close all windows/sessions)

2. **Restart Claude Code** from your terminal or application launcher

3. **Verify the statusline is working** - you should see a multi-line statusline at the bottom showing:
   - Directory and git branch
   - Session timing and reset countdown
   - Token usage and burn rate
   - Resource zones and recommendations

## Step 5: Verification and Testing

1. **Check statusline logs:**
   ```bash
   tail -f ~/.claude/statusline.log
   ```

2. **Test the statusline manually:**
   ```bash
   echo '{"workspace":{"current_dir":"'$(pwd)'"},"model":{"display_name":"Claude Sonnet 4"},"session_id":"test","version":"2.1.0"}' | ~/.claude/statusline.sh
   ```

3. **Expected output format:**
   ```
   =� ~/your-project   <? main   > Claude Sonnet 4   =� v2.1.0
    23h 45m until reset at 23:59 (5%) [=---------]
   =� 1,250 tok (45/min) " >� Context: 85% OK " =� ~$<1
   <� =� GREEN "  API 95% LEFT " < Wave:5 " =� Optimal - Ready for --wave-mode
   ```

## Troubleshooting

### Statusline not appearing
1. Check Claude Code is restarted completely
2. Verify settings.json syntax: `jq . ~/.claude/settings.json`
3. Check script permissions: `ls -la ~/.claude/statusline.sh`
4. Test script manually (Step 5, item 2)

### Script errors
1. Check the log file: `tail ~/.claude/statusline.log`
2. Ensure jq is installed: `which jq`
3. Verify file paths are correct

### JSON syntax errors
```bash
# Validate JSON
jq . ~/.claude/settings.json

# If invalid, restore backup
cp ~/.claude/settings.json.backup ~/.claude/settings.json
```

### Permission issues
```bash
# Fix script permissions
chmod +x ~/.claude/statusline.sh

# Check Claude config directory permissions
ls -la ~/.claude/
```

## Customization Options

### Modify token limits
Edit the script and adjust these values:
```bash
# Around line 178 in statusline.sh
limit="${CLAUDE_TOKEN_LIMIT:-200000}"
```

### Change resource zone thresholds
Edit the percentage thresholds in the script around lines 350-390.

### Adjust colors
The script uses ANSI color codes. Modify the color functions to customize appearance.

## Environment Variables

You can set these environment variables to customize behavior:
```bash
export CLAUDE_TOKEN_LIMIT=150000    # Custom token limit
export NO_COLOR=1                   # Disable colors
```

## Uninstalling

To remove the statusline:

1. **Remove from settings.json:**
   ```bash
   # Edit settings.json and remove the statusLine section
   nano ~/.claude/settings.json
   ```

2. **Remove files:**
   ```bash
   rm ~/.claude/statusline.sh
   rm ~/.claude/statusline.log
   rm ~/.claude/.usage_cache
   rm ~/.claude/.usage_state
   ```

3. **Restart Claude Code**

## Support

If you encounter issues:
1. Check the troubleshooting section above
2. Review the log file at `~/.claude/statusline.log`
3. Test the script manually with the verification commands
4. Ensure all prerequisites are installed

The statusline provides intelligent resource monitoring to help you make informed decisions about Claude Code usage and optimize your workflow efficiency.