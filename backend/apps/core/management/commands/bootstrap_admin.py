from django.core.management.base import BaseCommand

from apps.core.roles import create_initial_admin_user


class Command(BaseCommand):
    help = "Create the initial Pointy admin user only when no users exist."

    def add_arguments(self, parser):
        parser.add_argument("--username", default="admin")
        parser.add_argument("--email", default="")
        parser.add_argument("--password", required=True)

    def handle(self, *args, **options):
        admin = create_initial_admin_user(
            username=options["username"],
            email=options["email"],
            password=options["password"],
        )
        if admin is None:
            self.stdout.write("Skipped initial admin creation because setup is not available.")
            return
        self.stdout.write(self.style.SUCCESS(f"Created initial admin user '{admin.username}'."))
