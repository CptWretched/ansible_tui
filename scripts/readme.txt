How to add a new script (jr-friendly checklist)

Copy the template:

Shellcp scripts/_template_action.sh scripts/my_new_task.shShow more lines

Edit only the “Customize these 3 lines” section:

ShellTASK_NAME="My New Task"PLAYBOOK="${ROOT_DIR}/playbooks/my_new_task.yml"INVENTORY="${ROOT_DIR}/playbooks/inventory"Show more lines

Make it executable:

Shellchmod +x scripts/my_new_task.shShow more lines

Run TUI — it will appear automatically.
