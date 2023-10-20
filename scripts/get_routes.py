print(app.url_map)
print("These are API routes")
print(app.wsgi_app.app.mounts["/api"].url_map)
