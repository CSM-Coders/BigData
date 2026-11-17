#!/usr/bin/env bash
# crea el cluster de emr con hive y spark, usando el catálogo de glue como metastore
# si ya hay uno activo no crea otro
source "$(dirname "$0")/comun.sh"

verificar_sesion
nombres_buckets

ID_EMR="$(emr_id)"
if existe "$ID_EMR"; then
  echo "Ya existe el cluster $EMR_NOMBRE: $ID_EMR"
else
  aws iam get-role --role-name "$EMR_ROL" >/dev/null 2>&1 ||
    falla "No existe el rol $EMR_ROL en la cuenta."
  aws iam get-instance-profile --instance-profile-name "$EMR_PERFIL" >/dev/null 2>&1 ||
    falla "No existe el perfil $EMR_PERFIL en la cuenta."

  # una subred por defecto en una zona que tenga el tipo de instancia
  VPC="$(vpc_id)"
  ZONAS="$(aws ec2 describe-instance-type-offerings --location-type availability-zone \
    --filters "Name=instance-type,Values=$EMR_TIPO" --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' ' ')"
  SUBRED=""
  while read -r zona subred; do
    case " $ZONAS " in *" $zona "*) SUBRED="$subred"; break ;; esac
  done < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" "Name=default-for-az,Values=true" \
    --query 'Subnets[].[AvailabilityZone, SubnetId]' --output text | sort)
  existe "$SUBRED" || falla "No hay una subred por defecto con $EMR_TIPO."

  info "Creando el cluster $EMR_NOMBRE ($EMR_VERSION, 1 maestro y $EMR_NUCLEOS núcleos $EMR_TIPO)"
  ID_EMR="$(aws emr create-cluster --name "$EMR_NOMBRE" --release-label "$EMR_VERSION" \
    --applications Name=Hadoop Name=Hive Name=HCatalog Name=Spark \
    --instance-groups "InstanceGroupType=MASTER,InstanceCount=1,InstanceType=$EMR_TIPO" \
    "InstanceGroupType=CORE,InstanceCount=$EMR_NUCLEOS,InstanceType=$EMR_TIPO" \
    --service-role "$EMR_ROL" \
    --ec2-attributes "InstanceProfile=$EMR_PERFIL,KeyName=$EC2_LLAVE,SubnetId=$SUBRED" \
    --configurations "file://$DIR_CATALOGO/emr/configuracion.json" \
    --log-uri "s3://$BUCKET_ARTEFACTOS/emr-logs/" \
    --auto-termination-policy "IdleTimeout=$EMR_INACTIVO_S" \
    --tags "Proyecto=$PROYECTO" "Name=$EMR_NOMBRE" \
    --query ClusterId --output text)"
  echo "Cluster: $ID_EMR en $SUBRED"
fi

info "Esperando a que el cluster quede listo, tarda unos 10 minutos"
inicio="$(date +%s)"
while true; do
  read -r estado motivo < <(aws emr describe-cluster --cluster-id "$ID_EMR" --output text \
    --query 'Cluster.Status.[State, StateChangeReason.Message]')
  printf '%s  min %s  estado %s\n' "$(date '+%H:%M:%S')" "$(( ($(date +%s) - inicio) / 60 ))" "$estado"
  case "$estado" in
    WAITING|RUNNING) break ;;
    TERMINATING|TERMINATED|TERMINATED_WITH_ERRORS) falla "El cluster terminó: $motivo" ;;
  esac
  sleep 30
done

info "Cluster listo"
aws emr describe-cluster --cluster-id "$ID_EMR" --output table \
  --query 'Cluster.{Id:Id, Version:ReleaseLabel, Estado:Status.State, Maestro:MasterPublicDnsName}'
aws emr describe-cluster --cluster-id "$ID_EMR" --output table \
  --query 'Cluster.Applications[].{Aplicacion:Name, Version:Version}'
aws emr list-instances --cluster-id "$ID_EMR" --output table \
  --query 'Instances[].{Grupo:InstanceGroupId, Tipo:InstanceType, Estado:Status.State}'
echo
echo "Se apaga solo después de $(( EMR_INACTIVO_S / 60 )) minutos sin trabajo, o con terminar_emr.sh."
