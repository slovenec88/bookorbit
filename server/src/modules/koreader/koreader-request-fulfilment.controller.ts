import {
  Body,
  Controller,
  DefaultValuePipe,
  Get,
  Header,
  HttpCode,
  HttpStatus,
  Param,
  ParseBoolPipe,
  ParseIntPipe,
  Post,
  Query,
  UseGuards,
} from '@nestjs/common';
import { AuditAction, AuditResource } from '@bookorbit/types';

import { Auditable } from '../../common/decorators/auditable.decorator';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { Public } from '../../common/decorators/public.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { BookRequestService } from '../book-request/book-request.service';
import { DownloadClientConfigService } from '../book-request/download-clients/download-client-config.service';
import { GrabBookRequestDto } from '../book-request/dto/grab-book-request.dto';
import { InspectBookRequestReleaseDto } from '../book-request/dto/inspect-book-request-release.dto';
import { SearchBookRequestReleasesDto } from '../book-request/dto/search-book-request-releases.dto';
import { SelectReleaseUnitDto } from '../book-request/dto/select-release-unit.dto';
import { RequestFulfillmentService } from '../book-request/fulfillment/request-fulfillment.service';
import { RequestImportService } from '../book-request/fulfillment/request-import.service';
import { RequestVerificationService } from '../book-request/fulfillment/request-verification.service';
import { KoreaderAuthGuard } from './koreader-auth.guard';
import { KoreaderRequestGuard } from './koreader-request.guard';

@Public()
@UseGuards(KoreaderAuthGuard, KoreaderRequestGuard)
@Controller('koreader/plugin/requests')
export class KoreaderRequestFulfilmentController {
  constructor(
    private readonly requests: BookRequestService,
    private readonly fulfillment: RequestFulfillmentService,
    private readonly downloadClients: DownloadClientConfigService,
    private readonly imports: RequestImportService,
    private readonly verification: RequestVerificationService,
  ) {}

  @Get(':id/releases')
  @Header('Cache-Control', 'no-store')
  async listReleases(
    @Param('id', ParseIntPipe) id: number,
    @Query('refresh', new DefaultValuePipe(false), ParseBoolPipe) refresh: boolean | string,
    @CurrentUser() user: RequestUser,
  ) {
    await this.requests.assertCanFulfil(id, user);
    return this.fulfillment.listReleases(id, { refresh: refresh === true });
  }

  @Post(':id/releases/search')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'no-store')
  async searchReleases(@Param('id', ParseIntPipe) id: number, @Body() dto: SearchBookRequestReleasesDto, @CurrentUser() user: RequestUser) {
    await this.requests.assertCanFulfil(id, user);
    return this.fulfillment.listReleases(id, { refresh: true, overrides: dto });
  }

  @Post(':id/releases/inspect')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'no-store')
  async inspectRelease(@Param('id', ParseIntPipe) id: number, @Body() dto: InspectBookRequestReleaseDto, @CurrentUser() user: RequestUser) {
    await this.requests.assertCanFulfil(id, user);
    return this.fulfillment.inspectRelease(id, dto);
  }

  @Get(':id/download-clients')
  @Header('Cache-Control', 'no-store')
  async listDownloadClients(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    await this.requests.assertCanFulfil(id, user);
    return this.downloadClients.findEnabledSummaries();
  }

  @Post(':id/grab')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'no-store')
  @Auditable({
    action: AuditAction.BookRequestGrab,
    resource: AuditResource.BookRequest,
    getResourceId: (req) => Number(req.params.id),
    description: 'Sent a book request release from KOReader',
  })
  async grab(@Param('id', ParseIntPipe) id: number, @Body() dto: GrabBookRequestDto, @CurrentUser() user: RequestUser) {
    await this.requests.assertCanFulfil(id, user);
    return this.fulfillment.grab(id, dto, user);
  }

  @Get(':id/review')
  @Header('Cache-Control', 'no-store')
  async getReview(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    await this.requests.assertCanFulfil(id, user);
    return this.verification.getReview(id);
  }

  @Post(':id/force-file')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'no-store')
  @Auditable({
    action: AuditAction.BookRequestImport,
    resource: AuditResource.BookRequest,
    getResourceId: (req) => Number(req.params.id),
    description: 'Filed a held book request import from KOReader',
  })
  async forceFile(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    await this.requests.assertCanFulfil(id, user);
    await this.verification.fileHeldImport(id, user);
    return this.requests.getOne(id, user);
  }

  @Post(':id/discard-import')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'no-store')
  @Auditable({
    action: AuditAction.BookRequestImport,
    resource: AuditResource.BookRequest,
    getResourceId: (req) => Number(req.params.id),
    description: 'Discarded a held book request import from KOReader',
  })
  async discardImport(@Param('id', ParseIntPipe) id: number, @CurrentUser() user: RequestUser) {
    await this.requests.assertCanFulfil(id, user);
    await this.verification.discardHeldImport(id, user);
    return this.requests.getOne(id, user);
  }

  @Post(':id/downloads/:downloadId/select-unit')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'no-store')
  @Auditable({
    action: AuditAction.BookRequestImport,
    resource: AuditResource.BookRequest,
    getResourceId: (req) => Number(req.params.id),
    description: 'Chose a book from a multi-book release in KOReader',
  })
  async selectReleaseUnit(
    @Param('id', ParseIntPipe) id: number,
    @Param('downloadId', ParseIntPipe) downloadId: number,
    @Body() dto: SelectReleaseUnitDto,
    @CurrentUser() user: RequestUser,
  ) {
    await this.requests.assertCanFulfil(id, user);
    await this.imports.importChosenUnit(id, downloadId, dto.unitIndex);
    return this.requests.getOne(id, user);
  }

  @Post(':id/downloads/:downloadId/cancel')
  @HttpCode(HttpStatus.OK)
  @Header('Cache-Control', 'no-store')
  @Auditable({
    action: AuditAction.BookRequestRemoveDownload,
    resource: AuditResource.BookRequest,
    getResourceId: (req) => Number(req.params.id),
    description: 'Stopped a book request download from KOReader',
  })
  async cancelDownload(
    @Param('id', ParseIntPipe) id: number,
    @Param('downloadId', ParseIntPipe) downloadId: number,
    @CurrentUser() user: RequestUser,
  ) {
    await this.requests.assertCanFulfil(id, user);
    return this.requests.cancelDownload(id, downloadId, user);
  }
}
