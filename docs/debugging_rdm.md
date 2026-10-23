
# Debugging RDM

One of the things that can be prove helpful in the back trace provided in the containerized RDM deployment. Often you want to have more detail than it provides. That can easily be achived through selected logging along the path of modules called that leads to a stack trace. But has is that done?


1. Identifiy the Python package source from refernenced in the stack traince
2. Open that file in the editor and at the top add `from flask import current_app # DEBUG`
3. Find the place in the file you want to output content from and use a statement like ` current_app.logger.error(f"HELLO, again :frown: value -> {value}")`

The RDM files are implemented as Python packages. The path within the VS Code managed containers looks like `/home/vscode/.local/share/virtualenvs/caltechauthors-CCps2_L5/lib/python3.12/site-packages` where "caltechauthors-CCps2_L5" is the container id create by VS Code when it sets things up.


