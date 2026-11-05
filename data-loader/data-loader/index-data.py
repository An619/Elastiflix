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
    args = parser.parse_args()

    es_client = Elasticsearch(hosts=args.es_host, request_timeout=300)

    # Delete old index if it exists
    if es_client.indices.exists(index=args.index_name):
        es_client.indices.delete(index=args.index_name)
        print(f"Deleted existing index {args.index_name}")

    print(f"Creating index {args.index_name} with dynamic mapping (no schema)...")
    es_client.indices.create(index=args.index_name)

    print("Indexing data into Elasticsearch...")
    movies_file_path = os.path.join(args.data_folder, "movies.json.gz")
    with gzip.open(movies_file_path, 'rt') as file:
        movies_json = json.load(file)

    progress = tqdm(unit="docs", total=len(movies_json))
    for ok, action in helpers.parallel_bulk(es_client, actions_generator(movies_json, args.index_name), chunk_size=500):
        progress.update(1)

    print("\nAll tasks completed successfully.")

if __name__ == "__main__":
    main()