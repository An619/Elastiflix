import ElasticsearchAPIConnector from "@elastic/search-ui-elasticsearch-connector";

const SemanticConnector = new ElasticsearchAPIConnector({
  host: process.env.ES_HOST || "http://localhost:9200",
  index: process.env.ES_INDEX || "elastiflix-movies",
  apiKey: process.env.ES_API_KEY
}, (requestBody, requestState, queryConfig) => {

    if (!requestState.searchTerm) return requestBody;

    const body = {
      query: {
        semantic: {
          field: "plot_elser",
          query: requestState.searchTerm
        }
      }
    }

    requestBody.query = body.query;
    delete requestBody.sort;

    return requestBody;
  });

export default SemanticConnector;