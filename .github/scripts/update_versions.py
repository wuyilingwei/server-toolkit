import json
import os
import subprocess
import sys
import fnmatch

def run_git_command(command):
    try:
        result = subprocess.check_output(command, shell=True, stderr=subprocess.STDOUT)
        return result.decode('utf-8').strip()
    except subprocess.CalledProcessError as e:
        print(f"Error running git command: {command}\n{e.output.decode('utf-8')}")
        return None

def get_changed_files():
    # Get list of changed files in the last commit
    return run_git_command("git diff --name-only HEAD~1 HEAD").splitlines()

def get_file_content_at_revision(filename, revision):
    return run_git_command(f"git show {revision}:{filename}")

def bump_version(version, part='patch'):
    major, minor, patch = map(int, version.split('.'))
    if part == 'major':
        major += 1
        minor = 0
        patch = 0
    elif part == 'minor':
        minor += 1
        patch = 0
    else: # patch
        patch += 1
    return f"{major}.{minor}.{patch}"

def check_files_match(changed_files, patterns):
    for pattern in patterns:
        for file in changed_files:
            if fnmatch.fnmatch(file, pattern):
                return True
    return False

def main():
    config_path = 'config.json'
    
    if not os.path.exists(config_path):
        print("config.json not found")
        sys.exit(1)

    # Load current config
    with open(config_path, 'r', encoding='utf-8') as f:
        current_config = json.load(f)

    # Load previous config
    prev_content = get_file_content_at_revision(config_path, "HEAD~1")
    if not prev_content:
        print("Could not retrieve previous config.json")
        # Assume this is the first commit or something, just exit
        sys.exit(0)
    
    previous_config = json.loads(prev_content)
    
    changed_files = get_changed_files()
    print(f"Changed files: {changed_files}")

    config_changed = False
    new_tag = None

    # 1. Check Main Version
    main_track_files = current_config.get('track_files', [])
    main_files_changed = check_files_match(changed_files, main_track_files)
    
    manual_version_change = current_config['version'] != previous_config['version']
    
    if main_files_changed:
        print("Main tracked files changed.")
        if not manual_version_change:
            print("Main version not manually updated. Bumping patch version.")
            current_config['version'] = bump_version(current_config['version'], 'patch')
            config_changed = True
            new_tag = current_config['version']
        else:
            print("Main version manually updated.")
            new_tag = current_config['version']
    elif manual_version_change:
         print("Main version manually updated (no tracked files changed).")
         new_tag = current_config['version']

    # 2. Check Modules
    for module in current_config.get('modules', []):
        module_id = module.get('id')
        # Find previous module state
        prev_module = next((m for m in previous_config.get('modules', []) if m.get('id') == module_id), None)
        
        if not prev_module:
            continue

        track_files = module.get('track_files', [])
        if not track_files:
            continue

        module_files_changed = check_files_match(changed_files, track_files)
        module_manual_change = module['version'] != prev_module['version']

        if module_files_changed:
            print(f"Module {module_id} files changed.")
            if not module_manual_change:
                print(f"Module {module_id} version not manually updated. Bumping patch version.")
                module['version'] = bump_version(module['version'], 'patch')
                config_changed = True
            else:
                print(f"Module {module_id} version manually updated.")

    # Save config if changed
    if config_changed:
        with open(config_path, 'w', encoding='utf-8') as f:
            json.dump(current_config, f, indent=2, ensure_ascii=False)
        print("Updated config.json")
    
    # Output for GitHub Actions
    if 'GITHUB_OUTPUT' in os.environ:
        with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
            if new_tag:
                f.write(f"new_tag=v{new_tag}\n")
            f.write(f"config_changed={str(config_changed).lower()}\n")
    
    if new_tag:
        print(f"NEW_TAG: v{new_tag}")

if __name__ == "__main__":
    main()
