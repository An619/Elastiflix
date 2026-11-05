
import json
import os
import argparse
import gzip
from elasticsearch import Elasticsearch, helpers
from tqdm import tqdm

def actions_generator(movies_json, index_name):
    for movie in movies_json:
        movie["_index"] = index_name
        movie["_id"] = movie['id']
        yield movie

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data_folder', default='movies')
    parser.add_argument('--es_host', required=True)
    parser.add_argument('--index_name', default='elastiflix-movies')
    parser.add_argument('--template_path', required=True)
    args = parser.parse_args()

    es_client = Elasticsearch(hosts=args.es_host, request_timeout=300)

    if es_client.indices.exists(index=args.index_name):
        es_client.indices.delete(index=args.index_name)
        print(f"Deleted existing index {args.index_name}")

    print(f"Reading template from {args.template_path}")
    with open(args.template_path, 'r') as f:
        template = json.load(f)
    
    # Extract just the mappings part from the template
    mappings = template['template']['mappings']

    print(f"Creating index {args.index_name} with proper mappings...")
    es_client.indices.create(index=args.index_name, mappings=mappings)

    print("Indexing data into Elasticsearch...")
    movies_file_path = os.path.join(args.data_folder, "movies.json.gz")
    with gzip.open(movies_file_path, 'rt', encoding='utf-8') as file:
        movies_json = json.load(file)

    progress = tqdm(unit="docs", total=len(movies_json))
    for ok, action in helpers.parallel_bulk(es_client, actions_generator(movies_json, args.index_name), chunk_size=500):
        progress.update(1)

    print("\nAll tasks completed successfully.")

if __name__ == "__main__":
    main()
