from django.core.management.base import BaseCommand

from apps.core.roles import bootstrap_admin_user


class Command(BaseCommand):
    help = "Create the initial Pointy admin user only when no users exist."

    def add_arguments(self, parser):
        parser.add_argument("--username", default="admin")
        parser.add_argument("--email", default="")
        parser.add_argument("--password", default=None)

    def handle(self, *args, **options):
        admin = bootstrap_admin_user(
            username=options["username"],
            email=options["email"],
            password=options["password"],
        )
        if admin is None:
            self.stdout.write("Skipped bootstrap admin creation because users already exist.")
            return
        action = "Repaired" if getattr(admin, "_pointy_bootstrap_repaired", False) else "Created"
        self.stdout.write(self.style.SUCCESS(f"{action} bootstrap admin user '{admin.username}'."))
        generated_password = getattr(admin, "_pointy_bootstrap_password", None)
        if generated_password:
            self.stdout.write(f"Bootstrap admin password: {generated_password}")
