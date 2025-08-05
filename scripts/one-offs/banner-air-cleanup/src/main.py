import os
from google import genai
from dotenv import load_dotenv
import subprocess
import json
import csv
import argparse

def main():
    load_dotenv('../.env')
    parser = argparse.ArgumentParser(description="Extract WordPress post and user data from a Docker container.")
    parser.add_argument(
        "--container-name",
        default="wordpress",
        help="The name of the Docker container running WordPress. Default: wordpress"
    )
    parser.add_argument(
        "--output-csv-path",
        default="wp_content.csv",
        help="The path for the output CSV file. Default: wp_content.csv"
    )
    args = parser.parse_args()

    print("Welcome to the Banner Air Cleanup Tool!")

    cleanup = BannerAirCleanup(
        container_name=args.container_name,
        output_csv_path=args.output_csv_path
    )
    cleanup.extract_wp_data_to_csv()


def your_function(args):
    print(f"This function will handle the cleanup process for: {args}")

    return "Expected Output"

# Write a class


class BannerAirCleanup():

    def __init__(self, container_name="wordpress", output_csv_path="wp_content.csv"):
        load_dotenv()
        GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
        if not GEMINI_API_KEY:
            raise ValueError("GEMINI_API_KEY environment variable is not set.")
        print("GEMINI_API_KEY is set.")

        self.container_name = container_name
        self.output_csv_path = output_csv_path

        self.client = genai.Client(api_key=GEMINI_API_KEY)

        # Note: The model name 'gemini-2.5-flash' is hypothetical. 
        # Please use a valid model name like 'gemini-1.5-flash'.
        # self.model = genai.GenerativeModel("gemini-1.5-flash")
    
    def _run_wp_command(self, command):
        """Executes a WP-CLI command inside the specified Docker container."""
        docker_command = [
            "docker", "exec", self.container_name,
            "wp", *command
        ]
        try:
            print(f"Running command: {' '.join(docker_command)}")
            result = subprocess.run(
                docker_command,
                capture_output=True,
                text=True,
                check=True
            )
            return result.stdout
        except FileNotFoundError:
            print("Error: 'docker' command not found. Is Docker installed and in your PATH?")
            return None
        except subprocess.CalledProcessError as e:
            print(f"Error executing WP-CLI command: {e}")
            print(f"Stderr: {e.stderr}")
            return None

    def extract_wp_data_to_csv(self):
        """
        Extracts all posts and pages with author metadata and saves them to a CSV file.
        """
        print("Extracting posts and pages...")
        post_fields = "ID,post_title,post_author,post_date,post_type,guid"
        posts_json = self._run_wp_command(["post", "list", "--post_type=post,page", f"--fields={post_fields}", "--format=json"])
        
        if not posts_json:
            print("Failed to retrieve posts. Aborting.")
            return

        posts = json.loads(posts_json)
        
        author_ids = {post['post_author'] for post in posts}
        authors_data = {}

        print(f"Found {len(author_ids)} unique authors. Fetching their data...")
        for author_id in author_ids:
            user_fields = "ID,display_name,user_email,user_login,roles"
            user_json = self._run_wp_command(["user", "get", author_id, f"--fields={user_fields}", "--format=json"])
            if user_json:
                authors_data[author_id] = json.loads(user_json)

        combined_data = []
        print(f"Fetching content for {len(posts)} posts (this may take a moment)...")
        for post in posts:
            author_info = authors_data.get(post['post_author'], {})
            
            # Fetch and truncate post content
            post_content = self._run_wp_command(["post", "get", str(post['ID']), "--field=content"])
            content_excerpt = (post_content.strip()[:300] + '...') if post_content and len(post_content) > 300 else (post_content.strip() if post_content else "")

            combined_data.append({
                "post_id": post['ID'],
                "post_title": post['post_title'],
                "post_type": post['post_type'],
                "post_date": post['post_date'],
                "post_guid": post['guid'],
                "content_excerpt": content_excerpt,
                "author_id": post['post_author'],
                "author_display_name": author_info.get('display_name'),
                "author_email": author_info.get('user_email'),
                "author_login": author_info.get('user_login'),
            })

        if not combined_data:
            print("No data to write to CSV.")
            return

        print(f"Writing {len(combined_data)} rows to {self.output_csv_path}...")
        try:
            with open(self.output_csv_path, 'w', newline='', encoding='utf-8') as csvfile:
                fieldnames = combined_data[0].keys()
                writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(combined_data)
            print("Successfully created CSV file.")
        except IOError as e:
            print(f"Error writing to file {self.output_csv_path}: {e}")
        
    def analyze_content_via_ai(self, content):
        """
        Analyzes the content using the Gemini AI model.
        """

        prompt_parts = [
            "Analyze the following content and provide insights on potential issues.",
            "The idea is to identify whether the content is spam or legitimate as it relates to the intent and purpose of the website.",
            "Classify the content as 'Spam', 'Legitimate', or 'Uncertain' and provide a brief justification for your choice.",
            "Please return the classification and justification in JSON format like so: {'classification': 'Spam', 'justification': '...'}",
            "Below is the about page description of the website to help you understand its purpose:",
            "Greer’s Banner Air of Bakersfield, Inc. is Bakersfield’s expert heating & cooling company. We offer furnace and air conditioning services in and around Bakersfield. Please, feel free to contact us for more information on our services, products, and company.",
        ]
        # Join the parts of the prompt into a single string
        final_prompt = " ".join(prompt_parts)

        if not content:
            print("No content provided for analysis.")
            return None
        
        if isinstance(content, str):
            full_content = content.strip()
        elif isinstance(content, list):
            full_content = "\n".join(content).strip()
        else:
            print("Invalid content type for analysis. Expected str or list.")
            return None
        
        # Combine the prompt and the user content
        request_content = f"{final_prompt}\n\n---\n\nCONTENT TO ANALYZE:\n{full_content}"
        
        try:
            # Use the model instance created in __init__
            response = self.model.generate_content(request_content)
            return response.text
        except Exception as e:
            print(f"Error during AI analysis: {e}")
            return None


if __name__ == "__main__":
    main()