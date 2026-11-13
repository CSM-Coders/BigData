#!/usr/bin/env bash
# crea el bucket del datalake con sus zonas y el de artefactos
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets

crear_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "Ya existe s3://$bucket"
  else
    # en us-east-1 no se pasa LocationConstraint
    aws s3api create-bucket --bucket "$bucket" >/dev/null
    aws s3api wait bucket-exists --bucket "$bucket"
    echo "Creado s3://$bucket"
  fi
  aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-tagging --bucket "$bucket" \
    --tagging "TagSet=[{Key=Proyecto,Value=$PROYECTO}]"
}

info "Creando los buckets"
crear_bucket "$BUCKET_DATALAKE"
crear_bucket "$BUCKET_ARTEFACTOS"

# carpetas vacías para que las zonas se vean en la consola desde el inicio
info "Creando las zonas del datalake"
for zona in $ZONAS; do
  aws s3api put-object --bucket "$BUCKET_DATALAKE" --key "$zona/" >/dev/null
  echo "s3://$BUCKET_DATALAKE/$zona/"
done

info "Contenido del datalake"
aws s3 ls "s3://$BUCKET_DATALAKE/"
