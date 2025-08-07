package cmd

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/joho/godotenv"
	"github.com/spf13/cobra"
	"google.golang.org/genai"
)

// Roles is a custom type to handle JSON that may be a string or an array of strings.
type Roles []string

// UnmarshalJSON implements the json.Unmarshaler interface.
func (r *Roles) UnmarshalJSON(data []byte) error {
	// First, try to unmarshal as a single string.
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		*r = Roles{s}
		return nil
	}

	// If that fails, try to unmarshal as a slice of strings.
	var sl []string
	if err := json.Unmarshal(data, &sl); err == nil {
		*r = Roles(sl)
		return nil
	}

	return fmt.Errorf("cannot unmarshal %s into Roles", string(data))
}

// Data Structures
type Post struct {
	ID               int    `json:"ID"`
	Title            string `json:"post_title"`
	AuthorID         string `json:"post_author"`
	Date             string `json:"post_date"`
	Type             string `json:"post_type"`
	GUID             string `json:"guid"`
	ContentExcerpt   string
	Author           Author
	AIClassification string
	AIJustification  string
}

type Author struct {
	ID          string `json:"ID"`
	DisplayName string `json:"display_name"`
	Email       string `json:"user_email"`
	Login       string `json:"user_login"`
	Roles       Roles  `json:"roles"`
}

type AIResult struct {
	Classification string `json:"classification"`
	Justification  string `json:"justification"`
}

// Global variables for flags
var (
	dockerContainer string
	outputCSVPath   string
	analyzeContent  bool
	maxWorkers      = 10
)

var rootCmd = &cobra.Command{
	Use:   "banner-air-cleanup",
	Short: "A tool to extract and analyze WordPress content from a Docker container.",
	Long: `Extracts post and page data from a WordPress site running in a Docker
container, saves it to a CSV, and optionally analyzes the content for
spam using the Gemini AI API.`,
	Run: func(cmd *cobra.Command, args []string) {
		runApp()
	},
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().StringVar(&dockerContainer, "container-name", "wordpress", "The name of the Docker container running WordPress.")
	rootCmd.PersistentFlags().StringVar(&outputCSVPath, "output-csv-path", "wp_content.csv", "The path for the output CSV file.")
	rootCmd.PersistentFlags().BoolVar(&analyzeContent, "analyze-post-content-via-ai", false, "Enable AI analysis of post content.")
}

func runApp() {
	log.Println("Welcome to the Banner Air Cleanup Tool!")
	ctx := context.Background()

	// Check if container is running
	cmd := exec.CommandContext(ctx, "docker", "inspect", dockerContainer)
	if err := cmd.Run(); err != nil {
		log.Fatalf("Docker container '%s' not found or not running. Error: %v", dockerContainer, err)
	}
	log.Printf("Successfully connected to Docker and found container '%s'", dockerContainer)

	// Initialize AI Client if needed
	var genaiClient *genai.Client
	if analyzeContent {
		if err := godotenv.Load(); err != nil {
			log.Println("Warning: .env file not found, relying on environment variables.")
		}
		apiKey := os.Getenv("GEMINI_API_KEY")
		if apiKey == "" {
			log.Fatal("GEMINI_API_KEY environment variable is not set.")
		}
		log.Println("GEMINI_API_KEY is set.")
		client, err := genai.NewClient(ctx, &genai.ClientConfig{
			APIKey: apiKey,
		})
		if err != nil {
			log.Fatalf("Failed to create AI client: %v", err)
		}
		genaiClient = client
	}

	// Initialize CSV file
	csvFile, csvWriter := initializeCSV()
	defer csvFile.Close()
	defer csvWriter.Flush()

	// Get all posts
	log.Println("Extracting posts and pages...")
	posts, err := getPosts(ctx)
	if err != nil {
		log.Fatalf("Failed to retrieve posts: %v", err)
	}

	// Get unique authors
	authors, err := getAuthors(ctx, posts)
	if err != nil {
		log.Fatalf("Failed to retrieve authors: %v", err)
	}

	// Create channels and sync primitives
	postChan := make(chan Post, len(posts))
	resultChan := make(chan Post, len(posts))
	var wg sync.WaitGroup

	// Start workers
	log.Printf("Fetching content for %d posts (this may take a moment)...", len(posts))
	for i := 0; i < maxWorkers; i++ {
		wg.Add(1)
		go worker(ctx, &wg, postChan, resultChan, genaiClient)
	}

	// Distribute work
	for _, p := range posts {
		if author, ok := authors[p.AuthorID]; ok {
			p.Author = author
		}
		postChan <- p
	}
	close(postChan)

	// Collect results
	var combinedData []Post
	resultWg := &sync.WaitGroup{}
	resultWg.Add(1)
	go func() {
		defer resultWg.Done()
		for post := range resultChan {
			combinedData = append(combinedData, post)
		}
	}()

	wg.Wait()
	close(resultChan)
	resultWg.Wait()

	// Write to CSV
	writeCSV(csvWriter, combinedData)
	log.Printf("Processing complete! Wrote %d rows to %s", len(combinedData), outputCSVPath)
}

func runWPCommand(ctx context.Context, command []string) (string, error) {
	fullCmd := append([]string{"exec", dockerContainer, "wp"}, command...)
	cmd := exec.CommandContext(ctx, "docker", fullCmd...)
	var out bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		return "", fmt.Errorf("command failed: %w. Stderr: %s", err, stderr.String())
	}
	return out.String(), nil
}

func getPosts(ctx context.Context) ([]Post, error) {
	fields := "ID,post_title,post_author,post_date,post_type,guid"
	cmd := []string{"post", "list", "--post_type=post,page", fmt.Sprintf("--fields=%s", fields), "--format=json"}
	output, err := runWPCommand(ctx, cmd)
	if err != nil {
		return nil, err
	}
	var posts []Post
	if err := json.Unmarshal([]byte(output), &posts); err != nil {
		return nil, err
	}
	return posts, nil
}

func getAuthors(ctx context.Context, posts []Post) (map[string]Author, error) {
	authorIDs := make(map[string]struct{})
	for _, p := range posts {
		authorIDs[p.AuthorID] = struct{}{}
	}

	authorsData := make(map[string]Author)
	log.Printf("Found %d unique authors. Fetching their data...", len(authorIDs))
	for id := range authorIDs {
		fields := "ID,display_name,user_email,user_login,roles"
		cmd := []string{"user", "get", id, fmt.Sprintf("--fields=%s", fields), "--format=json"}
		output, err := runWPCommand(ctx, cmd)
		if err != nil {
			log.Printf("Warning: could not fetch author %s: %v", id, err)
			continue
		}
		var author Author
		if err := json.Unmarshal([]byte(output), &author); err != nil {
			log.Printf("Warning: could not parse author data for ID %s: %v", id, err)
			continue
		}
		authorsData[id] = author
	}
	return authorsData, nil
}

func worker(ctx context.Context, wg *sync.WaitGroup, postChan <-chan Post, resultChan chan<- Post, genaiClient *genai.Client) {
	defer wg.Done()
	for post := range postChan {
		// Fetch content
		content, err := runWPCommand(ctx, []string{"post", "get", strconv.Itoa(post.ID), "--field=content"})
		if err != nil {
			log.Printf("Error fetching content for post %d: %v", post.ID, err)
		} else {
			content = strings.TrimSpace(content)
			if len(content) > 300 {
				post.ContentExcerpt = content[:300] + "..."
			} else {
				post.ContentExcerpt = content
			}
		}

		// Analyze content if enabled
		post.AIClassification = "N/A"
		post.AIJustification = "N/A"
		if analyzeContent && genaiClient != nil && post.ContentExcerpt != "" {
			log.Printf("Analyzing content for post ID: %d...", post.ID)
			aiResult, err := analyzeContentViaAI(ctx, genaiClient, post.ContentExcerpt)
			if err != nil {
				log.Printf("Error analyzing post %d: %v", post.ID, err)
				post.AIClassification = "Error"
				post.AIJustification = err.Error()
			} else {
				post.AIClassification = aiResult.Classification
				post.AIJustification = aiResult.Justification
			}
			time.Sleep(1 * time.Second) // Avoid hitting API rate limits
		}
		resultChan <- post
	}
}

func analyzeContentViaAI(ctx context.Context, client *genai.Client, content string) (*AIResult, error) {
	prompt := `Analyze the following content and provide insights on potential issues. The idea is to identify whether the content is spam or legitimate as it relates to the intent and purpose of the website. Classify the content as 'Spam', 'Legitimate', or 'Uncertain' and provide a brief justification for your choice. Please return the classification and justification in valid JSON format like so: {"classification": "Spam", "justification": "..."}. Important: If you use double-quotes inside the "justification" string, you must escape them with a backslash (e.g., \"some quoted text\"). Below is the about page description of the website to help you understand its purpose: Greer’s Banner Air of Bakersfield, Inc. is Bakersfield’s expert heating & cooling company. We offer furnace and air conditioning services in and around Bakersfield. Please, feel free to contact us for more information on our services, products, and company.`

	fullPrompt := fmt.Sprintf("%s\n\n---\n\nCONTENT TO ANALYZE:\n%s", prompt, content)

	result, err := client.Models.GenerateContent(
		ctx,
		"gemini-1.5-flash", // or "gemini-2.5-flash" if available and preferred
		genai.Text(fullPrompt),
		nil,
	)
	if err != nil {
		return nil, fmt.Errorf("AI generation failed: %w", err)
	}

	rawJSON := result.Text()

	if rawJSON == "" {
		return nil, fmt.Errorf("failed to extract text from AI response: %w", err)
	}

	// Verify that rawJSON is valid JSON

	cleanedJSON := strings.Trim(rawJSON, " \n\t`")
	if after, ok := strings.CutPrefix(cleanedJSON, "json"); ok {
		cleanedJSON = after
	}
	cleanedJSON = strings.Trim(cleanedJSON, " \n\t`")

	var aiResult AIResult
	if err := json.Unmarshal([]byte(cleanedJSON), &aiResult); err != nil {
		return nil, fmt.Errorf("failed to decode AI JSON response: %w. Raw: %s", err, rawJSON)
	}

	if aiResult.Classification == "" || aiResult.Justification == "" {
		return nil, fmt.Errorf("AI response has incorrect format. Raw: %s", rawJSON)
	}

	return &aiResult, nil
}

func initializeCSV() (*os.File, *csv.Writer) {
	file, err := os.Create(outputCSVPath)
	if err != nil {
		log.Fatalf("Error creating CSV file %s: %v", outputCSVPath, err)
	}
	writer := csv.NewWriter(file)
	headers := []string{
		"post_id", "post_title", "post_type", "post_date", "post_guid",
		"content_excerpt", "author_id", "author_display_name", "author_email",
		"author_login", "ai_classification", "ai_justification",
	}
	if err := writer.Write(headers); err != nil {
		log.Fatalf("Error writing CSV headers: %v", err)
	}
	return file, writer
}

func writeCSV(writer *csv.Writer, data []Post) {
	for _, post := range data {
		row := []string{
			strconv.Itoa(post.ID),
			post.Title,
			post.Type,
			post.Date,
			post.GUID,
			post.ContentExcerpt,
			post.AuthorID,
			post.Author.DisplayName,
			post.Author.Email,
			post.Author.Login,
			post.AIClassification,
			post.AIJustification,
		}
		if err := writer.Write(row); err != nil {
			log.Printf("Error writing row to CSV for post %d: %v", post.ID, err)
		}
	}
}
