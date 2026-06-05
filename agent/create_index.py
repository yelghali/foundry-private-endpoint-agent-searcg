"""Create a small Azure AI Search index and upload sample documents.

Because the search service has public network access DISABLED, this script must
run from a host INSIDE the virtual network (for example a jump box / VM on the
pe-subnet or a peered network). Run it from your workstation only if you have
private connectivity (VPN / ExpressRoute / Bastion) to the VNet.

Auth uses Entra ID (DefaultAzureCredential); the signed-in identity needs
'Search Index Data Contributor' and 'Search Service Contributor' on the search
service. Run `az login` first.
"""

from __future__ import annotations

import config
from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    SearchableField,
    SearchField,
    SearchFieldDataType,
    SearchIndex,
    SimpleField,
)

SAMPLE_DOCS = [
    {
        "id": "1",
        "title": "Refund policy",
        "content": "Customers can request a refund within 30 days of purchase. "
        "Refunds are processed to the original payment method within 5 business days.",
    },
    {
        "id": "2",
        "title": "Shipping options",
        "content": "Standard shipping takes 3-5 business days. Express shipping "
        "delivers within 1-2 business days for an extra fee.",
    },
    {
        "id": "3",
        "title": "Warranty",
        "content": "All hardware products include a 1-year limited warranty that "
        "covers manufacturing defects but not accidental damage.",
    },
]


def main() -> None:
    endpoint = config.get("AI_SEARCH_ENDPOINT")
    index = config.index_name()
    credential = DefaultAzureCredential()

    fields = [
        SimpleField(name="id", type=SearchFieldDataType.String, key=True),
        SearchableField(name="title", type=SearchFieldDataType.String),
        SearchableField(name="content", type=SearchFieldDataType.String),
    ]

    index_client = SearchIndexClient(endpoint=endpoint, credential=credential)
    index_client.create_or_update_index(SearchIndex(name=index, fields=fields))
    print(f"Index '{index}' created/updated on {endpoint}")

    search_client = SearchClient(endpoint=endpoint, index_name=index, credential=credential)
    result = search_client.upload_documents(documents=SAMPLE_DOCS)
    succeeded = sum(1 for r in result if r.succeeded)
    print(f"Uploaded {succeeded}/{len(SAMPLE_DOCS)} documents.")


if __name__ == "__main__":
    main()
